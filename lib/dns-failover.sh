#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Points the public DNS record(s) for FLUXER_HA_DNS_NAME at THIS site. Started
# in the background by controller.sh as soon as this site becomes the Patroni
# primary, and again every 10 minutes to undo any drift. Only the primary
# runs it, so two sites can't fight over the record.
#
# The provider is FLUXER_HA_DNS_PROVIDER: cloudflare, exec or none
# (fluxer-ha/dns/<provider>.sh). Each defines dns_configured and dns_update.
set -u
HA_NAME=dns-failover
. "$(dirname "$0")/common.sh"

PROVIDER=$(envget FLUXER_HA_DNS_PROVIDER); PROVIDER=${PROVIDER:-none}
case $PROVIDER in cloudflare | exec | none) ;; *) alert "unknown FLUXER_HA_DNS_PROVIDER '$PROVIDER'"; exit 1 ;; esac
. ./fluxer-ha/dns/"$PROVIDER".sh
[ "$PROVIDER" != none ] || exit 0
dns_configured || { alert "DNS failover ($PROVIDER) is not configured; traffic still points wherever DNS says"; exit 1; }

update() {
	kind=$1; ip=$2
	[ -n "$ip" ] || return 0
	delay=2
	attempt=1
	while :; do
		is_primary || { log "no longer primary; abandoning the $kind update"; return 1; }
		if dns_update "$kind" "$ip"; then
			log "$kind record -> $ip (ttl $(envnum FLUXER_HA_DNS_TTL 60))"
			return 0
		fi
		[ "$attempt" -ne 3 ] || alert "DNS $kind update failing; traffic still points at the old site. Retrying."
		sleep "$delay"
		attempt=$((attempt + 1))
		[ "$delay" -ge 30 ] || delay=$((delay * 2))
	done
}

# One copy at a time: a copy still retrying must not be joined by another.
exec 9>"$STATE_DIR/dns.lock"
flock -n 9 || { log "another dns-failover is already running"; exit 0; }
update A "$(envget FLUXER_HA_PUBLIC_IPV4)" &
update AAAA "$(envget FLUXER_HA_PUBLIC_IPV6)" &
wait
