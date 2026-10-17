#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Game day: a planned, zero-loss switchover to the peer. See docs/testing.md.
# Usage: HA_GAMEDAY=1 ./gd-switchover.sh   (on the current PRIMARY)
# Run it again from the new primary to switch back.
. "$(dirname "$0")/gd-lib.sh"

is_primary || die "run this on the current PRIMARY"
require_healthy_cluster
peer_is_sync || die "peer $PEER is not the synchronous standby"
PEER_PUBLIC=$(envget FLUXER_HA_PEER_PUBLIC_IPV4)

confirm "switchover-to-$PEER"
inject
# The patronictl flags work with the pinned Patroni (lab, 4.1.5).
pctl switchover --primary "$SELF" --candidate "$PEER" --force

wait_for 120 "peer $PEER reports /primary" peer_is_primary
edge_stopped() { ! docker compose --profile app ps --status running --services | grep -qx edge; }
wait_for 30  "this site's edge stopped (controller L3)" edge_stopped
dns_ok() { [ "$(dig +short A "$DNS_NAME" @1.1.1.1 | tail -n 1)" = "$PEER_PUBLIC" ]; }
wait_for 180 "public DNS (1.1.1.1) -> $PEER_PUBLIC" dns_ok
wait_for 180 "https://$TLS_NAME/api/_health OK via $PEER_PUBLIC" https_ok "$PEER_PUBLIC"
wait_for 300 "this site ($SELF) rejoined as the synchronous standby" self_is_sync
log "done. Run analyze.mjs --inject $INJECT_AT --profile planned --verify"
