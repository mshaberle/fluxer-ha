#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Game day: crash one application service on the PRIMARY. See docs/testing.md.
# Usage: sudo HA_GAMEDAY=1 ./gd-kill-service.sh <service>
#
# Sends SIGKILL to the container's main process from the HOST, so Docker sees
# a crash rather than a manual stop. `docker kill` counts as a manual stop and
# skips the restart policy (lab, Docker 29.9: a `docker kill`ed container stayed
# exited until something else started it). Expected recovery:
#   warm services: Docker restarts them (restart: unless-stopped, compose line 206)
#   cold services: controller.sh restarts them within ~2 s (restart: "no", 05-deploy/ha.compose.yml)
# Data-tier services (postgres, etcd, valkey, seaweedfs, nats, meilisearch) are
# refused here. Those are node-level scenarios.
. "$(dirname "$0")/gd-lib.sh"

[ "$(id -u)" = 0 ] || die "this drill signals a container's process from the host: run it with sudo"
SVC=${1:-}
case "$SVC" in
	api|worker|gateway|edge|push|app-proxy|admin|media-proxy|static-proxy|users|users-shard|messages|messages-shard|snowflakes|snowflakes-shard|gifs|gifs-shard|unfurl|unfurl-shard|livekit) ;;
	*) die "service must be an application service (see the header)";;
esac
is_primary || die "run this on the current PRIMARY"
require_healthy_cluster
cid=$(docker compose --profile app ps -q "$SVC")
[ -n "$cid" ] || die "$SVC is not running"
pid=$(docker inspect -f '{{.State.Pid}}' "$cid")

confirm "kill-$SVC"
inject
kill -9 "$pid"
log "SIGKILL sent to $SVC (pid $pid)"

running_healthy() {
	c=$(docker compose --profile app ps -q "$SVC"); [ -n "$c" ] || return 1
	st=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "$c")
	[ "$st" = "running healthy" ]
}
sleep 2
wait_for 300 "$SVC running and healthy again" running_healthy
is_primary && log "still primary (expected: a service crash never causes a failover)" || log "UNEXPECTED: no longer primary"
