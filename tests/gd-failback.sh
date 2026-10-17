#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Game day: automatic failback to the preferred site. See docs/testing.md.
# Usage: HA_GAMEDAY=1 ./gd-failback.sh   (on the PREFERRED site, while it is the PRIMARY)
#
# Moves the primary to the peer with a planned switchover, then waits for
# failback.sh to bring it back on its own. Set a short window for the drill in
# fluxer-ha/.env.shared on BOTH sites, then run fluxer-ha/build-env.sh, e.g.
#   FLUXER_HA_FAILBACK_STABLE_SECONDS=600
# and put it back to 3600 afterwards. The drill doesn't change it for you.
. "$(dirname "$0")/gd-lib.sh"

STATE=fluxer-ha/state/failback.state
sget() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1; }
PREFERRED=$(envget FLUXER_HA_PREFERRED_SITE)
STABLE=$(envget FLUXER_HA_FAILBACK_STABLE_SECONDS); STABLE=${STABLE:-3600}
JOBS_WAIT=$(envget FLUXER_HA_FAILBACK_JOBS_WAIT_SECONDS); JOBS_WAIT=${JOBS_WAIT:-1800}
SELF_PUBLIC=$(envget FLUXER_HA_PUBLIC_IPV4)

[ "$SELF" = "$PREFERRED" ] || die "run this on the preferred site ($PREFERRED)"
is_primary || die "run this while $SELF is the PRIMARY"
[ ! -e fluxer-ha/state/failback.latched ] || die "automatic failback is held or backing off: $(cat fluxer-ha/state/failback.latched)"
systemctl is-active --quiet fluxer-ha-failback.timer || die "fluxer-ha-failback.timer is not active"
[ -z "$(envget FLUXER_HA_FAILBACK_HOURS)" ] || die "FLUXER_HA_FAILBACK_HOURS is set; clear it for the drill"
[ "$STABLE" -le 1800 ] || die "window is ${STABLE}s; set FLUXER_HA_FAILBACK_STABLE_SECONDS<=1800 for the drill"
require_healthy_cluster
peer_is_sync || die "peer $PEER is not the synchronous standby"

confirm "failback-drill"
inject
# The patronictl flags work with the pinned Patroni (lab, 4.1.5).
pctl switchover --primary "$SELF" --candidate "$PEER" --force
wait_for 120 "peer $PEER reports /primary" peer_is_primary
wait_for 300 "this site ($SELF) rejoined as the synchronous standby" self_is_sync
window=$(sget window)
log "failback.sh window: ${window:-unknown}s (more than $STABLE means a relapse doubled it)"
since_ok() { [ -n "$(sget since)" ]; }
wait_for 600 "failback.sh started the stability clock" since_ok

wait_for $(( ${window:-$STABLE} + JOBS_WAIT + 300 )) "$SELF is the primary again (automatic failback)" is_primary
FAILBACK_AT=$(date -u -d "@$(sget last_failback)" +%Y-%m-%dT%H:%M:%SZ)
echo "FAILBACK_AT=$FAILBACK_AT"
dns_ok() { [ "$(dig +short A "$DNS_NAME" @1.1.1.1 | tail -n 1)" = "$SELF_PUBLIC" ]; }
wait_for 180 "public DNS (1.1.1.1) -> $SELF_PUBLIC" dns_ok
wait_for 180 "https://$TLS_NAME/api/_health OK via $SELF_PUBLIC" https_ok "$SELF_PUBLIC"
wait_for 300 "peer $PEER rejoined as the synchronous standby" peer_is_sync
journalctl -u fluxer-ha-failback --since "@$(( $(sget last_failback) - 60 ))" --no-pager | tail -n 20
log "done. Run analyze.mjs twice: --inject $INJECT_AT and --inject $FAILBACK_AT, both --profile planned --verify."
log "Put FLUXER_HA_FAILBACK_STABLE_SECONDS back to 3600 on both sites."
