#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Game day: add latency to this host's WireGuard egress for N seconds.
# See docs/testing.md.
# Usage (root, on either site): HA_GAMEDAY=1 ./gd-link-latency.sh 50 300
# Expected: synchronous commits slow by about the added delay, no failover, no
# data loss. The delay is capped at 200 ms, so etcd's default 1000 ms election
# timeout isn't approached (etcd 3.6.15 defaults: heartbeat 100 ms, election
# 1000 ms; lab: +50 ms, no failover).
# Safety: reverted by a trap, AND by a detached failsafe that removes the qdisc
# SECS+30 s later even if this shell dies.
. "$(dirname "$0")/gd-lib.sh"
[ "$(id -u)" = 0 ] || die "this drill changes the network (iptables/tc): run it with sudo"

DELAY=${1:-50}; SECS=${2:-300}
[ "$DELAY" -le 200 ] || die "delay capped at 200 ms"
command -v tc >/dev/null || die "tc (iproute2) not installed"
tc qdisc show dev wg0 | grep -q netem && die "a netem qdisc already exists on wg0"
require_healthy_cluster

confirm "latency-${DELAY}ms"
revert() { tc qdisc del dev wg0 root 2>/dev/null || true; log "netem removed"; }
trap revert EXIT INT TERM
nohup sh -c "sleep $((SECS + 30)); tc qdisc del dev wg0 root netem 2>/dev/null" >/dev/null 2>&1 &
inject
tc qdisc add dev wg0 root netem delay "${DELAY}ms"
log "+${DELAY}ms on wg0 egress for ${SECS}s"
sleep "$SECS"
