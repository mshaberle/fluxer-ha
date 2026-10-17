#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Game day: cut ONLY the site1 <-> site2 WireGuard path for N
# seconds. Both sites keep reaching the witness. See docs/testing.md.
# Run it in STAGING first.
# Usage (root, on either site): HA_GAMEDAY=1 ./gd-site-link-cut.sh 120
# Expected: NO failover, because the primary keeps its lease through the
# witness. Replication stops, so after a commit stall Patroni drops to async
# and P6 alerts. Once the link is back, the replica catches up and is sync again.
# Safety: trap plus a detached failsafe remove the rules SECS+30 s later.
#
# How the cut works: it drops the WireGuard tunnel's own UDP packets to and
# from the peer's endpoint. Dropping on wg0 in INPUT/OUTPUT does NOT work:
# Docker-published ports (Postgres 5432, Patroni 8008, etcd, Valkey, the filer)
# are DNATed to containers, so that traffic takes the FORWARD chain and kept
# flowing. Found in the lab, 2026-10-15: the old version cut only SSH.
. "$(dirname "$0")/gd-lib.sh"
[ "$(id -u)" = 0 ] || die "this drill changes the network (iptables/tc): run it with sudo"

SECS=${1:-120}
command -v iptables >/dev/null || die "iptables not installed"
require_healthy_cluster
WITNESS_EP=$(envget FLUXER_HA_ETCD_HOSTS | tr ',' '\n' | grep -v "$PEER_WG" | grep -v "$(envget FLUXER_HA_LOCAL_WG_IP)")
docker compose exec -T etcd etcdctl --endpoints="$WITNESS_EP" endpoint health </dev/null >/dev/null 2>&1 || die "witness not reachable from here"

# The peer's tunnel endpoint (its public IP:port), from the WireGuard peer
# whose allowed IP is the peer's WireGuard address.
PEER_KEY=$(wg show wg0 allowed-ips | awk -v ip="$PEER_WG/32" '$2==ip {print $1}')
PEER_EP=$(wg show wg0 endpoints | awk -v k="$PEER_KEY" '$1==k {print $2}')
PEER_EP_IP=${PEER_EP%:*}; PEER_EP_PORT=${PEER_EP##*:}
[ -n "$PEER_EP_IP" ] && [ -n "$PEER_EP_PORT" ] || die "can't find the WireGuard endpoint of $PEER_WG"
RULE_IN="-p udp -s $PEER_EP_IP --sport $PEER_EP_PORT -j DROP"
RULE_OUT="-p udp -d $PEER_EP_IP --dport $PEER_EP_PORT -j DROP"

confirm "site-link-cut"
del() {
	iptables -D INPUT $RULE_IN 2>/dev/null || true
	iptables -D OUTPUT $RULE_OUT 2>/dev/null || true
}
revert() { del; log "site link restored"; }
trap revert EXIT INT TERM
nohup sh -c "sleep $((SECS + 30)); iptables -D INPUT $RULE_IN; iptables -D OUTPUT $RULE_OUT" >/dev/null 2>&1 &
inject
iptables -I INPUT $RULE_IN
iptables -I OUTPUT $RULE_OUT
log "link to $PEER ($PEER_WG) cut for ${SECS}s. Expect NO role change."
sleep "$SECS"
