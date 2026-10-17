#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Limits what reaches the Docker-published ports on this host's WireGuard
# address. On a site:
#   the peer site   everything the HA overlay publishes (Postgres, Patroni,
#                   etcd, Valkey, S3, the filer)
#   the witness     etcd only (2379 client, 2380 peer)
# On the witness: the two sites, etcd only.
#   FLUXER_HA_FIREWALL_ALLOW   optional extra holes, "ip:port,ip:port" (TCP,
#                   over WireGuard), e.g. a monitoring host scraping Patroni.
#                   Each one widens the boundary; the lab uses one for its
#                   database writer.
#   anything else   nothing, and in particular nothing that reaches the
#                   WireGuard address WITHOUT coming through WireGuard. Linux
#                   accepts a packet for any local address on any interface,
#                   and Docker's DNAT for a port published on 10.77.0.1
#                   matches whatever interface it arrived on, so a neighbour
#                   on the provider's LAN that routes 10.77.0.0/24 at this
#                   host reached every port here, the filer and etcd's
#                   unauthenticated peer port included (lab, S14).
#
# The rules go in Docker's DOCKER-USER chain. Docker-published ports are
# DNATed to the container in PREROUTING, so the traffic crosses FORWARD, not
# INPUT, and ordinary host rules (ufw, an INPUT policy) never see it (docs/lab-results.md F12).
# --ctorigdstport/--ctorigdst match what the client asked for, before the DNAT.
#
#   firewall.sh apply    (re)build the rules; idempotent
#   firewall.sh check    exit 0 if the rules are in place and current
#   firewall.sh ensure   check; if wrong, re-apply and alert; then write the
#                        result to <Fluxer dir>/fluxer-ha/state/firewall.status
#   firewall.sh remove   delete them
#
# The one runtime part of fluxer-ha with a privilege: iptables needs
# CAP_NET_ADMIN. fluxer-ha-firewall.service (at boot, after Docker and
# WireGuard) and fluxer-ha-firewall-check.timer (every 30 s) run it as the
# Fluxer user with that one capability, not as root (docs/security.md). Both
# still run this root-owned copy, so the code holding the capability can't be
# edited by the account it runs as.
set -eu
# Root runs a root-owned copy (/usr/local/lib/fluxer-ha/firewall.sh), which
# finds the Fluxer directory in the root-owned config; it reads .env as data.
CONF=/etc/fluxer-ha/fluxer-ha.conf
FLUXER_DIR=$(sed -n 's/^FLUXER_DIR=//p' "$CONF" 2>/dev/null | tail -n 1)
ROLE=$(sed -n 's/^ROLE=//p' "$CONF" 2>/dev/null | tail -n 1); ROLE=${ROLE:-site}
cd "${FLUXER_DIR:-$(dirname "$0")/..}"

envget() { sed -n "s/^$1=//p" .env | tail -n 1; }
WG_IF=$(envget FLUXER_HA_WG_INTERFACE); WG_IF=${WG_IF:-wg0}
LOCAL=$(envget FLUXER_HA_LOCAL_WG_IP)
ALLOW=$(envget FLUXER_HA_FIREWALL_ALLOW)
CHAIN=FLUXER-HA
STATE_DIR=${FLUXER_HA_STATE_DIR:-$(pwd)/fluxer-ha/state}

# Removing needs no settings: it runs while leaving HA too, after .env has
# lost them (fluxer-ha leave), so it comes before the checks below.
if [ "${1:-}" = remove ]; then
	WG_IF=$(envget FLUXER_HA_WG_INTERFACE 2>/dev/null); WG_IF=${WG_IF:-wg0}
	while iptables -C DOCKER-USER -j FLUXER-HA 2>/dev/null; do iptables -D DOCKER-USER -j FLUXER-HA; done
	while iptables -C DOCKER-USER -i "$WG_IF" -j FLUXER-HA 2>/dev/null; do iptables -D DOCKER-USER -i "$WG_IF" -j FLUXER-HA; done
	iptables -F FLUXER-HA 2>/dev/null || true
	iptables -X FLUXER-HA 2>/dev/null || true
	echo "firewall: removed"
	exit 0
fi

ip4() { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
die() { echo "firewall: $*" >&2; exit 1; }
echo "$WG_IF" | grep -Eqx '[A-Za-z0-9_.-]{1,15}' || die "FLUXER_HA_WG_INTERFACE is not an interface name"
ip4 "$LOCAL" || die "FLUXER_HA_LOCAL_WG_IP is not an IPv4 address"
if [ "$ROLE" = witness ]; then
	# The sites, from the etcd cluster definition: name=http://ip:2380,...
	# The sites' addresses: FLUXER_HA_SITE_WG_IPS (init writes it), else parsed
	# from the etcd member list. That list shrinks during a recovery (operations.md,
	# "Primary and witness both lost"), so the explicit setting comes first.
	SITES=$(envget FLUXER_HA_SITE_WG_IPS | tr ',' ' ')
	[ -n "$SITES" ] || SITES=$(envget FLUXER_HA_ETCD_INITIAL_CLUSTER | tr ',' '\n' | sed -n 's|^site[0-9]*=http://\([0-9.]*\):2380$|\1|p' | tr '\n' ' ' | sed 's/ *$//')
	[ "$(echo $SITES | wc -w)" = 2 ] || die "can't read the two sites' addresses from FLUXER_HA_ETCD_INITIAL_CLUSTER"
	for a in $SITES; do ip4 "$a" || die "site address '$a' is not IPv4"; done
else
	PEER=$(envget FLUXER_HA_PEER_WG_IP)
	WITNESS=$(envget FLUXER_HA_WITNESS_WG_IP)
	ip4 "$PEER" || die "FLUXER_HA_PEER_WG_IP is not an IPv4 address"
	ip4 "$WITNESS" || die "FLUXER_HA_WITNESS_WG_IP is not an IPv4 address"
fi
for a in $(echo "$ALLOW" | tr ',' ' '); do
	ip4 "${a%:*}" && echo "${a##*:}" | grep -Eqx '[0-9]{1,5}' || die "FLUXER_HA_FIREWALL_ALLOW entry '$a' is not ip:port"
done

# The rule set, one iptables argument list per line, in order. Every packet
# Docker forwards passes through it; whatever isn't about this host's
# WireGuard address leaves it unchanged (the final RETURN).
rules() {
	# Replies to connections this host's containers opened (filer-sync and
	# s3-mirror pull from the peer; Patroni talks to every etcd member).
	echo "-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
	# This host's own containers, which reach the published ports through the
	# WireGuard address too (Patroni lists its own etcd that way).
	echo "-i docker0 -j RETURN"
	echo "-i br-+ -j RETURN"
	if [ "$ROLE" = witness ]; then
		for a in $SITES; do
			echo "-s $a/32 -i $WG_IF -p tcp -m conntrack --ctorigdstport 2379 -j RETURN"
			echo "-s $a/32 -i $WG_IF -p tcp -m conntrack --ctorigdstport 2380 -j RETURN"
		done
	else
		echo "-s $PEER/32 -i $WG_IF -j RETURN"
		echo "-s $WITNESS/32 -i $WG_IF -p tcp -m conntrack --ctorigdstport 2379 -j RETURN"
		echo "-s $WITNESS/32 -i $WG_IF -p tcp -m conntrack --ctorigdstport 2380 -j RETURN"
	fi
	for a in $(echo "$ALLOW" | tr ',' ' '); do
		echo "-s ${a%:*}/32 -i $WG_IF -p tcp -m conntrack --ctorigdstport ${a##*:} -j RETURN"
	done
	echo "-i $WG_IF -j DROP"
	# The WireGuard address from any other interface (S14).
	echo "-m conntrack --ctorigdst $LOCAL -j DROP"
	echo "-j RETURN"
}

# What `iptables -S CHAIN` prints for the rules above.
expected() {
	echo "-N $CHAIN"
	rules | sed "s|^|-A $CHAIN |"
}
current() { iptables -S "$CHAIN" 2>/dev/null; }
jump_present() { iptables -C DOCKER-USER -j "$CHAIN" 2>/dev/null; }

check() {
	iptables -S DOCKER-USER >/dev/null 2>&1 || { echo "firewall: no DOCKER-USER chain (is Docker running?)" >&2; return 1; }
	jump_present || { echo "firewall: DOCKER-USER does not send traffic to $CHAIN" >&2; return 1; }
	# iptables -S normalises some spellings; compare on the canonical form.
	[ "$(current | tr -s ' ')" = "$(expected | tr -s ' ')" ] || { echo "firewall: $CHAIN rules differ from the expected set" >&2; return 1; }
	# The jump must come before anything that ACCEPTs.
	[ "$(iptables -S DOCKER-USER | sed -n 2p)" = "-A DOCKER-USER -j $CHAIN" ] ||
		{ echo "firewall: the $CHAIN jump is not the first rule in DOCKER-USER" >&2; return 1; }
}

# Builds the new rule set in a separate chain, points DOCKER-USER at it, and
# only then drops the old one, so there is never a moment with a partial rule
# set. A lock keeps two runs (the unit and ha-health.sh) from interleaving:
# before it, two concurrent applies could leave DROP ahead of the allow rules.
apply() {
	iptables -S DOCKER-USER >/dev/null 2>&1 || { echo "firewall: no DOCKER-USER chain (is Docker running?)" >&2; exit 1; }
	new=$CHAIN-NEW
	# Leftovers from a run that died half-way, and the jump of earlier
	# versions, which sent only WireGuard traffic here.
	while iptables -C DOCKER-USER -j "$new" 2>/dev/null; do iptables -D DOCKER-USER -j "$new"; done
	while iptables -C DOCKER-USER -i "$WG_IF" -j "$CHAIN" 2>/dev/null; do iptables -D DOCKER-USER -i "$WG_IF" -j "$CHAIN"; done
	iptables -N "$new" 2>/dev/null || iptables -F "$new"
	rules | while read -r r; do
		# shellcheck disable=SC2086 # each line is an argument list
		iptables -A "$new" $r
	done
	iptables -I DOCKER-USER 1 -j "$new"
	while jump_present; do iptables -D DOCKER-USER -j "$CHAIN"; done
	iptables -F "$CHAIN" 2>/dev/null || true
	iptables -X "$CHAIN" 2>/dev/null || true
	iptables -E "$new" "$CHAIN"
	check
	if [ "$ROLE" = witness ]; then echo "firewall: $LOCAL: sites $SITES etcd only over $WG_IF${ALLOW:+, extra $ALLOW}; everything else dropped"
	else echo "firewall: $LOCAL: peer $PEER all, witness $WITNESS etcd only, over $WG_IF${ALLOW:+, extra $ALLOW}; everything else dropped"; fi
}

remove() {
	while jump_present; do iptables -D DOCKER-USER -j "$CHAIN"; done
	while iptables -C DOCKER-USER -i "$WG_IF" -j "$CHAIN" 2>/dev/null; do iptables -D DOCKER-USER -i "$WG_IF" -j "$CHAIN"; done
	iptables -F "$CHAIN" 2>/dev/null || true
	iptables -X "$CHAIN" 2>/dev/null || true
	echo "firewall: removed"
}

exec 8>"$STATE_DIR/firewall.lock"
flock -w 30 8 || { echo "firewall: another run holds the lock" >&2; exit 1; }

# For ha-health.sh: "ok <unix time>" or "fail <unix time> <reason>".
ensure() {
	tmp=$(mktemp "$STATE_DIR/firewall.status.XXXXXX")
	if why=$(check 2>&1); then
		printf 'ok %s\n' "$(date +%s)" >"$tmp"
	else
		apply >/dev/null 2>&1 || true
		msg="firewall rules were missing or wrong ($why); re-applied"
		# The URL comes from .env, which the Fluxer user writes: hand curl
		# nothing but a plain http(s) URL.
		au=$(envget FLUXER_HA_ALERT_URL)
		if echo "$au" | grep -Eqx 'https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+'; then
			printf 'url = "%s"\n' "$au" | curl -fsS -m 5 --proto =http,https --config - -d "fluxer-ha $(envget FLUXER_HA_SITE): $msg" >/dev/null 2>&1 || true
		fi
		echo "firewall: $msg" >&2
		if check >/dev/null 2>&1; then printf 'ok %s re-applied\n' "$(date +%s)"; else printf 'fail %s %s\n' "$(date +%s)" "$why"; fi >"$tmp"
	fi
	chmod 644 "$tmp"
	mv -f "$tmp" "$STATE_DIR/firewall.status"
}

case "${1:-}" in
	apply) apply ;;
	check) check ;;
	ensure) ensure ;;
	remove) remove ;;
	*) echo "usage: firewall.sh apply|check|ensure|remove" >&2; exit 2 ;;
esac
