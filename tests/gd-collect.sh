#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Collect evidence after ANY game day. Read-only. See docs/testing.md.
# Usage on each site host: HA_GAMEDAY=1 ./gd-collect.sh "2026-10-09 14:00:00"
# Produces fluxer-ha/state/evidence/gd-<site>-<time>.tar.gz (mode 600)
# with the cluster state and logs since the given time. The logs are not for
# everyone on the host (13 S8).
. "$(dirname "$0")/gd-lib.sh"
umask 077

SINCE=${1:?usage: gd-collect.sh "<since, e.g. 2026-10-09 14:00:00>"}
D=$(mktemp -d)
pctl list >"$D/patroni-list.txt" 2>&1 || true
pctl history >"$D/patroni-history.txt" 2>&1 || true   # promotion LSNs/times = timeline switches
docker compose exec -T etcd etcdctl --endpoints="$(envget FLUXER_HA_ETCD_HOSTS)" endpoint status -w table >"$D/etcd-status.txt" 2>&1 || true
docker compose exec -T valkey valkey-cli INFO replication >"$D/valkey-replication.txt" 2>&1 || true
journalctl -u fluxer-ha-controller --since "$SINCE" >"$D/controller.log" 2>&1 || true
cp fluxer-ha/state/dns.log "$D/" 2>/dev/null || true
journalctl -k --since "$SINCE" | grep -i -E 'watchdog|softdog' >"$D/kernel-watchdog.log" 2>&1 || true
for s in postgres etcd valkey-role-link s3-mirror api worker gateway edge; do
	docker compose --profile app logs --no-color --since "$(date -u -d "$SINCE" +%Y-%m-%dT%H:%M:%SZ)" "$s" >"$D/$s.log" 2>&1 || true
done
docker compose --profile app ps >"$D/ps.txt" 2>&1 || true
mkdir -p fluxer-ha/state/evidence
OUTF="fluxer-ha/state/evidence/gd-$SELF-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
tar -czf "$OUTF" -C "$D" . && rm -rf "$D"
echo "evidence: $OUTF"
