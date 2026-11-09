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
# With FLUXER_HA_DNS_PROVIDER=none (a floating IP or a load balancer), public
# DNS doesn't follow the primary, so there's nothing to wait for (lab, 2026-10-30).
RESOLVER=$(envget FLUXER_HA_DNS_CHECK_RESOLVER); RESOLVER=${RESOLVER:-1.1.1.1}
dns_ok() { [ "$(dig +short A "$DNS_NAME" @"$RESOLVER" | tail -n 1)" = "$PEER_PUBLIC" ]; }
if [ "$(envget FLUXER_HA_DNS_PROVIDER)" = none ]; then log "DNS provider none: not waiting for public DNS"
else wait_for 180 "public DNS ($RESOLVER) -> $PEER_PUBLIC" dns_ok; fi
wait_for 180 "https://$TLS_NAME/api/_health OK via $PEER_PUBLIC" https_ok "$PEER_PUBLIC"
wait_for 300 "this site ($SELF) rejoined as the synchronous standby" self_is_sync
log "done. Run analyze.mjs --inject $INJECT_AT --profile planned --verify"
