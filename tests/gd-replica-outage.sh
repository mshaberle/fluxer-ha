#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Game day: stop the REPLICA's Postgres for N seconds. See docs/testing.md.
# Usage on the REPLICA: HA_GAMEDAY=1 ./gd-replica-outage.sh 120
# Expected:
#   - the primary keeps accepting writes after at most a short commit stall
#     (bounded by wal_sender_timeout + loop_wait, docs/testing.md)
#   - Patroni drops to async
#   - heartbeat P6 alerts
#   - after restart: catch-up, then this node is the synchronous standby again
# Risk while it runs: losing the primary now means NO automatic failover (by design).
. "$(dirname "$0")/gd-lib.sh"

SECS=${1:-120}
is_replica || die "run this on the REPLICA"
require_healthy_cluster
self_is_sync || die "this replica isn't the synchronous standby"

confirm "replica-outage"
trap 'docker compose start postgres >/dev/null; log "replica postgres started"' EXIT INT TERM
inject
docker compose stop postgres
log "replica postgres stopped for ${SECS}s"
sleep "$SECS"
docker compose start postgres
trap - EXIT INT TERM
wait_for 600 "this node is the synchronous standby again" self_is_sync
