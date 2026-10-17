#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Check (injects nothing): your own reverse proxy in front of the bundled edge
# (`install.sh --tls proxy`, docs/reverse-proxies.md) fences the spare and
# keeps your other sites up. Run it on BOTH sites, before and after a
# switchover. Usage:
#
#   HA_GAMEDAY=1 fluxer-ha/tests/gd-proxy-fence.sh [other.site.example ...]
#
# Name your proxy's other sites as arguments to check they keep answering.
# It goes through the proxy on this host (127.0.0.1:443), by the
# certificate's name (FLUXER_DOMAIN):
#   primary   the Fluxer domain answers 200 with a certificate this host trusts
#   spare     the edge isn't running, and the proxy CLOSES the connection
#             instead of answering 502 (handle_errors 502 503 504 { abort }):
#             a keep-alive or HTTP/2 client then reconnects and re-resolves
#             DNS instead of staying on the dead site (docs/lab-results.md F16)
#   both      the certificate the proxy presents for the Fluxer domain hasn't
#             passed the point where Caddy renews it (a third of its lifetime
#             left; on the spare: the copy that sync-edge-certs put there,
#             which it serves after a promotion), and every other site you
#             named answers below 500
. "$(dirname "$0")/gd-lib.sh"

case :$(envget COMPOSE_FILE): in *:docker-compose.proxy.yml:*) ;; *) die "this check is for --tls proxy (docker-compose.proxy.yml in COMPOSE_FILE)" ;; esac
bad=0
ok() { log "OK   $*"; }
no() { log "FAIL $*"; bad=1; }
url="https://$TLS_NAME/api/_health"
at="--resolve $TLS_NAME:443:127.0.0.1"

edge=$(docker compose ps --status running -q edge 2>/dev/null)
if is_primary; then
	log "this site ($SELF) is the PRIMARY"
	[ -n "$edge" ] && ok "the edge is running" || no "the edge isn't running on the primary"
	# shellcheck disable=SC2086
	c=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' $at "$url" 2>&1) || true
	[ "$c" = 200 ] && ok "$url answers 200 through the proxy, certificate trusted" || no "$url through the proxy: $c"
elif is_replica; then
	log "this site ($SELF) is the SPARE"
	[ -z "$edge" ] && ok "the edge isn't running" || no "the edge is running on the spare: two sites could serve"
	for proto in --http1.1 --http2; do
		# shellcheck disable=SC2086
		# set -e: the failure is what we expect, so catch its exit code.
		rc=0; out=$(curl -sk -m 10 $proto -o /dev/null -w '%{http_code}' $at "$url" 2>/dev/null) || rc=$?
		case $rc:$out in
			52:* | 56:* | 92:* | 16:*) ok "$proto: the proxy closed the connection without an answer (curl exit $rc)" ;;
			*:502 | *:503 | *:504) no "$proto: the proxy answered ${out}. Keep-alive clients stay on this site; add 'handle_errors 502 503 504 { abort }' to the Fluxer site block" ;;
			*:200) no "$proto: 200 from the SPARE: two sites are serving" ;;
			*) no "$proto: unexpected (curl exit $rc, $out)" ;;
		esac
	done
	# Two requests on one connection: with abort, the second needs a new one.
	# shellcheck disable=SC2086
	n=$(curl -sk -m 10 --http1.1 -o /dev/null -o /dev/null -w '%{num_connects}\n' $at "$url" "$url" 2>/dev/null | awk '{s+=$1} END {print s+0}')
	[ "$n" -ge 2 ] && ok "a second request on the same connection had to reconnect ($n connections for 2 requests)" || no "the spare kept the connection open ($n connection for 2 requests)"
else
	die "Patroni reports neither primary nor replica here; check fluxer-ha status first"
fi

# The certificate this proxy presents for the Fluxer domain. Caddy renews when
# a third of a certificate's lifetime is left, so a served certificate past
# that point means renewal (on the primary) or the copy (on the spare) has
# stalled. Lifetimes vary: 90 days from Let's Encrypt, 12 hours from Caddy's
# local CA, so the check uses the certificate's own dates.
chain=$(mktemp); trap 'rm -f "$chain"' EXIT
echo | openssl s_client -connect 127.0.0.1:443 -servername "$TLS_NAME" -showcerts 2>/dev/null | sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' >"$chain"
crt=$(sed -n '1,/-END CERTIFICATE-/p' "$chain")
if [ -z "$crt" ]; then
	no "no certificate for $TLS_NAME from the proxy on this host"
elif ! printf '%s\n' "$crt" | openssl verify -untrusted "$chain" >/dev/null 2>&1; then
	no "the certificate for $TLS_NAME isn't trusted by this host: on the spare, the primary's copy hasn't arrived (lab F40)"
else
	nb=$(date -u -d "$(printf '%s\n' "$crt" | openssl x509 -noout -startdate | cut -d= -f2)" +%s)
	na=$(date -u -d "$(printf '%s\n' "$crt" | openssl x509 -noout -enddate | cut -d= -f2)" +%s)
	now=$(date -u +%s); left=$((na - now)); life=$((na - nb))
	if [ "$left" -le 0 ]; then no "the certificate for $TLS_NAME has expired"
	elif [ $((left * 3)) -lt "$life" ]; then no "the certificate for $TLS_NAME is past its renewal point ($((left / 3600)) h of $((life / 3600)) h left): is fluxer-ha-certs.timer copying it?"
	else ok "the certificate for $TLS_NAME has $((left / 3600)) h of its $((life / 3600)) h left (renewal at a third)"; fi
fi

for site in "$@"; do
	c=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' --resolve "$site:443:127.0.0.1" "https://$site/" 2>/dev/null) || true
	case $c in [1-4][0-9][0-9]) ok "other site $site answers ($c)" ;; *) no "other site $site: ${c:-no answer}" ;; esac
done

[ "$bad" = 0 ] && log "proxy fence: all checks passed" || { log "proxy fence: FAILED"; exit 1; }
