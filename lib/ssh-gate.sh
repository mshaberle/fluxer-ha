#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The ONLY thing the peer site can run over SSH. `fluxer-ha ssh-link` installs
# it as /usr/local/lib/fluxer-ha/ssh-gate.sh and as the forced command for the
# peer's key in ~fluxer-ha/.ssh/authorized_keys:
#
#   restrict,from="<peer WireGuard IP>",command="/usr/local/lib/fluxer-ha/ssh-gate.sh" ssh-ed25519 AAAA... fluxer-ha@<peer>
#
# `restrict` turns off forwarding and the pty; `from=` accepts the key only
# from the peer's WireGuard address (WireGuard binds that address to the peer's
# key, so it can't be spoofed inside the mesh). The requested command arrives
# in SSH_ORIGINAL_COMMAND and must be exactly one of these verbs:
#
#   env-hash       sha256 of fluxer-ha/.env.shared + fluxer-ha/ha.images.lock.yml (drift check).
#                  Integrity only: a compromised peer can lie.
#   cert-receive   a tar of the Fluxer certificate on stdin, installed into
#                  this site's certificate storage. Refused on the primary.
#
# The fluxer-ha user is not in the docker group. The gate re-runs itself
# through sudo, with a fixed verb, as the Fluxer user (RUN_USER in
# /etc/fluxer-ha/fluxer-ha.conf: the account that installed Fluxer and owns
# .env; root only with `--allow-root`). One sudoers rule allows exactly that:
#
#   fluxer-ha ALL=(<RUN_USER>) NOPASSWD: /usr/local/lib/fluxer-ha/ssh-gate.sh env-hash, /usr/local/lib/fluxer-ha/ssh-gate.sh cert-receive
#
# This file and every directory above it must be root-owned and not writable
# by fluxer-ha or RUN_USER, or the sudo rule becomes a shell as RUN_USER. It
# lives outside the Fluxer directory, which fluxer-ha may not be able to
# traverse (home directories are mode 700).
set -eu
SELF=/usr/local/lib/fluxer-ha/ssh-gate.sh
CONF=/etc/fluxer-ha/fluxer-ha.conf
RUN_USER=$(sed -n 's/^RUN_USER=//p' "$CONF" 2>/dev/null | tail -n 1)
[ -n "$RUN_USER" ] || { echo "ssh-gate: no RUN_USER in $CONF" >&2; exit 1; }

if [ "$(id -un)" != "$RUN_USER" ]; then
	case "${SSH_ORIGINAL_COMMAND:-}" in
		env-hash | cert-receive) exec sudo -n -u "$RUN_USER" "$SELF" "$SSH_ORIGINAL_COMMAND" ;;
		*)
			# What the peer sent, printable characters only and at most 200,
			# so it can't forge further log lines.
			logger -t fluxer-ha-ssh "refused: $(printf '%s' "${SSH_ORIGINAL_COMMAND:-<interactive>}" | tr -c '[:print:]' '?' | cut -c1-200)" 2>/dev/null || true
			echo "ssh-gate: not allowed" >&2
			exit 126
			;;
	esac
fi

FLUXER_DIR=$(sed -n 's/^FLUXER_DIR=//p' "$CONF" 2>/dev/null | tail -n 1)
[ -n "$FLUXER_DIR" ] && [ -f "$FLUXER_DIR/fluxer-ha/.env.shared" ] || { echo "ssh-gate: no Fluxer directory with fluxer-ha/.env.shared configured in /etc/fluxer-ha/fluxer-ha.conf" >&2; exit 1; }
cd "$FLUXER_DIR"
envget() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1; }
logger -t fluxer-ha-ssh "allowed: ${1:-}" 2>/dev/null || true
UTIL_IMAGE=$(envget FLUXER_HA_UTIL_IMAGE)
UTIL_IMAGE=${UTIL_IMAGE:-alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6}
STATE_DIR=$FLUXER_DIR/fluxer-ha/state
RESTART_MIN=$(envget FLUXER_HA_CADDY_RESTART_MIN_SECONDS); RESTART_MIN=${RESTART_MIN:-3600}
PROJECT=$(envget COMPOSE_PROJECT_NAME); PROJECT=${PROJECT:-fluxer}

case "${1:-}" in
	env-hash)
		cat fluxer-ha/.env.shared fluxer-ha/ha.images.lock.yml 2>/dev/null | sha256sum | cut -d' ' -f1
		;;
	cert-receive)
		# Where the certificate lives (FLUXER_HA_CERT_MODE):
		#   edge    upstream's bundled edge (--tls bundled): the edge-data
		#           volume. The edge is stopped on the replica and loads the
		#           file when it starts, so nothing restarts here.
		#   caddy   your own Caddy container: FLUXER_HA_CADDY_DATA_VOLUME, and
		#           FLUXER_HA_CADDY_CONTAINER is restarted (rate limited)
		#   none    you handle certificates yourself; refused
		MODE=$(envget FLUXER_HA_CERT_MODE)
		# The certificate is for the name the edge or your proxy serves: FLUXER_DOMAIN.
DOMAIN=$(envget FLUXER_DOMAIN); DOMAIN=${DOMAIN:-$(envget FLUXER_HA_DNS_NAME)}
		case ${MODE:-none} in
			edge) VOLUME=${PROJECT}_edge-data; CADDY= ;;
			caddy) VOLUME=$(envget FLUXER_HA_CADDY_DATA_VOLUME); CADDY=$(envget FLUXER_HA_CADDY_CONTAINER) ;;
			*) echo "cert-receive: FLUXER_HA_CERT_MODE is ${MODE:-none}; refusing" >&2; exit 1 ;;
		esac
		[ -n "$DOMAIN" ] && [ -n "$VOLUME" ] || { echo "cert-receive: no domain or volume configured" >&2; exit 1; }
		# Never overwrite the certificate the primary is serving and renewing.
		if curl -fsS -m 2 -o /dev/null http://127.0.0.1:8008/primary 2>/dev/null; then
			echo "cert-receive: this site is the primary; refusing" >&2
			exit 1
		fi
		umask 077   # the key stays private, here and in the volume
		tmp=$(mktemp -d)
		trap 'rm -rf "$tmp"' EXIT
		# 1 MiB is far more than one certificate, key and metadata file.
		head -c 1048576 >"$tmp/in.tar"
		# Only regular files and directories, and only these paths:
		#   caddy/  caddy/certificates/  caddy/certificates/<issuer>/
		#   caddy/certificates/<issuer>/<domain>/<domain>.{crt,key,json}
		if tar -tvf "$tmp/in.tar" | grep -qv '^[-d]'; then
			echo "cert-receive: links or special files in the archive; refusing" >&2
			exit 1
		fi
		d=$(printf '%s' "$DOMAIN" | sed 's/[.]/\\./g')
		if tar -tf "$tmp/in.tar" | grep -Evq "^(\./)?caddy/(certificates/([A-Za-z0-9][^/]*/($d/($d\.(crt|key|json))?)?)?)?$"; then
			echo "cert-receive: unexpected paths in the archive; refusing" >&2
			exit 1
		fi
		# Before `join` has created the edge's volume, create it as Compose
		# would (with its labels), so Compose adopts it without a warning.
		if [ "${MODE}" = edge ] && ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
			docker volume create --label "com.docker.compose.project=$PROJECT" --label com.docker.compose.volume=edge-data "$VOLUME" >/dev/null
		fi
		sum() { docker run --rm -v "$VOLUME":/d:ro "$UTIL_IMAGE" sh -c "cat /d/caddy/certificates/*/$DOMAIN/$DOMAIN.crt 2>/dev/null | sha256sum"; }
		before=$(sum)
		# Unpack here, with the same GNU tar that listed it, check what
		# actually landed, and give the container only a fresh archive of
		# that tree: the container's busybox tar never parses the peer's
		# bytes, so the two tars can't disagree about a crafted archive.
		mkdir "$tmp/x"
		tar -C "$tmp/x" --no-same-owner --no-same-permissions --no-overwrite-dir -xf "$tmp/in.tar"
		if [ -n "$(find "$tmp/x" -mindepth 1 ! -type f ! -type d)" ] ||
			(cd "$tmp/x" && find . -mindepth 1 | sed 's|^\./||') | grep -Evq "^caddy(/certificates(/[A-Za-z0-9][^/]*(/$d(/$d\.(crt|key|json))?)?)?)?$"; then
			echo "cert-receive: unexpected files in the archive; refusing" >&2
			exit 1
		fi
		[ -d "$tmp/x/caddy" ] || { echo "cert-receive: empty archive; refusing" >&2; exit 1; }
		tar -C "$tmp/x" --owner=0 --group=0 -cf - caddy |
			docker run --rm -i -v "$VOLUME":/dst "$UTIL_IMAGE" tar -C /dst -xf -
		mkdir -p "$STATE_DIR"
		if [ "$(sum)" != "$before" ]; then
			echo "cert-receive: installed a new certificate for $DOMAIN"
			[ -z "$CADDY" ] || touch "$STATE_DIR/caddy-restart-pending"
		else
			echo "cert-receive: certificate for $DOMAIN unchanged"
		fi
		[ -n "$CADDY" ] && [ -e "$STATE_DIR/caddy-restart-pending" ] || exit 0
		# Caddy caches certificates in memory; only a restart loads the copied
		# file (a reload doesn't). A compromised primary could send a new
		# certificate on every call to keep restarting this host's Caddy and
		# the other sites it serves, so restarts are limited to one per
		# RESTART_MIN. A deferred restart stays pending for a later call
		# (the timer runs hourly); the previous certificate stays valid
		# meanwhile, since Caddy renews 30 days before expiry.
		last=$(cat "$STATE_DIR/caddy-restart-at" 2>/dev/null || echo 0)
		echo "$last" | grep -Eqx '[0-9]+' || last=0
		now=$(date +%s)
		if [ $((now - last)) -lt "$RESTART_MIN" ]; then
			logger -t fluxer-ha-ssh "cert-receive: Caddy restart deferred (last one $((now - last)) s ago)" 2>/dev/null || true
			echo "cert-receive: restart of $CADDY deferred; the last one was $((now - last)) s ago" >&2
			exit 0
		fi
		echo "$now" >"$STATE_DIR/caddy-restart-at"
		if docker restart "$CADDY" >/dev/null 2>&1; then
			rm -f "$STATE_DIR/caddy-restart-pending"
			echo "cert-receive: restarted $CADDY"
		else
			echo "cert-receive: installed, but restarting $CADDY failed" >&2
		fi
		;;
	*)
		exit 126
		;;
esac
