#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Game day: pause media replication (filer-sync) on the REPLICA
# for N seconds. See docs/testing.md.
# Usage on the REPLICA: HA_GAMEDAY=1 ./gd-mirror-pause.sh 600
# Expected: heartbeat P6 stops (ha-health.sh: filer-sync unhealthy); after the
# restart filer.sync resumes from its saved offset, catches up within seconds,
# and the alert clears. Lab: 5 files uploaded during a 120 s pause were all
# on the spare 1 s after the resume.
# Combine it with probe.mjs UPLOAD_EVERY_MS to see media lag grow.
. "$(dirname "$0")/gd-lib.sh"

SECS=${1:-600}
is_replica || die "run this on the REPLICA"
confirm "mirror-pause"
trap 'docker compose start filer-sync >/dev/null; log "filer-sync started"' EXIT INT TERM
inject
docker compose stop filer-sync
log "filer-sync paused for ${SECS}s"
sleep "$SECS"
docker compose start filer-sync
trap - EXIT INT TERM
healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q filer-sync)")" = healthy ]; }
wait_for 300 "filer-sync healthy (streaming again)" healthy
