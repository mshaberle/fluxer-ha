#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Game day: the witness's etcd member is down for N seconds. See docs/testing.md.
# Usage on the WITNESS host:
#   HA_GAMEDAY=1 ./gd-witness-outage.sh 300
# Expected: no user impact, no failover, heartbeat P6 alerts, full recovery once the member is back.
set -eu
[ "${HA_GAMEDAY:-}" = "1" ] || { echo "refusing: set HA_GAMEDAY=1" >&2; exit 1; }
SECS=${1:-300}
# Where `fluxer-ha install witness` put it (~/fluxer-witness by default).
WITNESS_DIR=${WITNESS_DIR:-$(sed -n 's/^FLUXER_DIR=//p' /etc/fluxer-ha/fluxer-ha.conf 2>/dev/null)}
cd "${WITNESS_DIR:?set WITNESS_DIR}"
dc() { docker compose "$@"; }   # settings come from .env next to compose.yml
ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

eps=$(sed -n 's/^FLUXER_HA_ETCD_INITIAL_CLUSTER=//p' .env | sed 's#[a-z0-9]*=http://\([0-9.]*\):2380#\1:2379#g')
# etcd's HTTP /health needs no credentials, so the witness never has to hold
# any (etcd auth is on: 13 S1). `etcdctl endpoint health` without a user now
# reports every member unhealthy.
for ep in $(echo "$eps" | tr ',' ' '); do
	curl -fsS -m 3 "http://$ep/health" | grep -q '"health":"true"' || { echo "ABORT: etcd member $ep not healthy" >&2; exit 1; }
done

printf 'Type the scenario name (witness-outage) to inject: '; read -r a; [ "$a" = witness-outage ] || exit 1
trap 'dc start etcd; echo "$(ts) witness etcd started"' EXIT INT TERM
echo "INJECT_AT=$(ts)"
dc stop etcd
echo "$(ts) witness etcd stopped for ${SECS}s. Expect: P6 heartbeat alert, NO role change."
sleep "$SECS"
