# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=sh
#
# Shared helpers for the gd-*.sh game-day scripts. See docs/testing.md.
# Source it; don't execute it. Every gd script:
#   - refuses to run unless HA_GAMEDAY=1 is set
#   - checks its preconditions, then asks you to type the scenario name
#   - prints INJECT_AT=<UTC ms> (pass this to analyze.mjs --inject)
#   - reverts its fault on exit, including Ctrl-C

set -eu
# The Fluxer directory: installed as <fluxer>/fluxer-ha/tests/, or from fluxer-ha's config.
HA_DIR=${HA_DIR:-$(sed -n 's/^FLUXER_DIR=//p' /etc/fluxer-ha/fluxer-ha.conf 2>/dev/null)}
HA_DIR=${HA_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}
cd "$HA_DIR"

[ "${HA_GAMEDAY:-}" = "1" ] || { echo "refusing: set HA_GAMEDAY=1 to run game-day scripts" >&2; exit 1; }

envget() { sed -n "s/^$1=//p" .env | tail -n 1; }
SELF=$(envget FLUXER_HA_SITE)
PEER=$(envget FLUXER_HA_PEER_SITE)
PEER_WG=$(envget FLUXER_HA_PEER_WG_IP)
DNS_NAME=$(envget FLUXER_HA_DNS_NAME)
# The certificate is for FLUXER_DOMAIN, which can differ from the DNS record's
# name: connect to the address public DNS returns, by the certificate's name.
TLS_NAME=$(envget FLUXER_DOMAIN); TLS_NAME=${TLS_NAME:-$DNS_NAME}
https_ok() { curl -fsS -m 5 -o /dev/null --resolve "$TLS_NAME:443:$1" "https://$TLS_NAME/api/_health"; }

# Every exec gets </dev/null: `docker compose exec` forwards stdin even with -T,
# and would swallow the typed confirmation read later (docs/lab-results.md F22).
pctl() { docker compose exec -T postgres /opt/patroni/bin/patronictl -c /etc/patroni.yml "$@" </dev/null; }
code() { curl -s -m 2 -o /dev/null -w '%{http_code}' "$1" || true; }
is_primary() { [ "$(code http://127.0.0.1:8008/primary)" = 200 ]; }
is_replica() { [ "$(code http://127.0.0.1:8008/replica)" = 200 ]; }
peer_is_primary() { [ "$(code "http://$PEER_WG:8008/primary")" = 200 ]; }
peer_is_sync() { [ "$(code "http://$PEER_WG:8008/sync")" = 200 ]; }
self_is_sync() { [ "$(code http://127.0.0.1:8008/sync)" = 200 ]; }

ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }      # GNU date (Linux hosts)
log() { echo "$(ts) $*"; }
die() { echo "ABORT: $*" >&2; exit 1; }

# A healthy cluster: one leader, one sync standby, all etcd members healthy.
require_healthy_cluster() {
	pctl list | grep -q 'Leader' || die "no Patroni leader"
	pctl list | grep -q 'Sync Standby' || die "no synchronous standby; automatic failover isn't possible, so don't test now"
	docker compose exec -T etcd etcdctl --endpoints="$(envget FLUXER_HA_ETCD_HOSTS)" endpoint health </dev/null >/dev/null 2>&1 ||
		die "etcd not fully healthy"
}

confirm() {
	echo "Scenario: $1"
	echo "Make sure probe.mjs is running from OUTSIDE both sites."
	printf 'Type the scenario name (%s) to inject: ' "$1"
	read -r answer || die "no confirmation read (stdin closed)"
	[ "$answer" = "$1" ] || die "not confirmed"
}

inject() { INJECT_AT=$(ts); echo "INJECT_AT=$INJECT_AT"; }

# wait_for <timeout_s> <description> <command...>: prints the elapsed time since INJECT_AT.
wait_for() {
	limit=$1; what=$2; shift 2
	start=$(date +%s)
	until "$@" >/dev/null 2>&1; do
		[ $(( $(date +%s) - start )) -lt "$limit" ] || { log "TIMEOUT after ${limit}s waiting for: $what"; return 1; }
		sleep 1
	done
	log "OK ($(( $(date +%s) - start ))s after the wait began): $what"
}
