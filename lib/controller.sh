#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The controller. Runs on BOTH sites as fluxer-ha-controller.service.
# See docs/architecture.md, "Who starts what".
#
# Desired state, rechecked every POLL seconds:
#   local Patroni is the primary  -> the COLD tier runs (the edge, API, worker,
#                                    LiveKit, ...) and public DNS points here
#   anything else                 -> the COLD tier is stopped (fail-closed fencing)
# The WARM tier runs on both sites. Before the first cold start after becoming
# primary, the snowflake clock gate must pass.
#
# It never promotes or demotes Postgres (only Patroni does), never touches the
# data tier, and never applies a configuration change: every `docker compose
# up` here uses --no-deps, and the warm check also --no-recreate. Changes go
# out with `fluxer-ha rollout`, one site at a time. (Without that, an .env edit
# once made both lab sites recreate etcd and Postgres within seconds of each
# other: docs/lab-results.md F27.)
set -u
HA_NAME=controller
. "$(dirname "$0")/common.sh"
. ./fluxer-ha/tiers.sh

POLL=2
WARM_EVERY=30
DNS_EVERY=600
KV_TABLE=$(envget FLUXER_POSTGRES_KV_TABLE); KV_TABLE=${KV_TABLE:-fluxer_kv}
PGDB=$(envget FLUXER_POSTGRES_DATABASE); PGDB=${PGDB:-fluxer}

dc() { docker compose --profile app "$@"; }
# Your hooks (docs/operations.md, "Hooks"). Each gets 60 s: the loop that
# stops the app tier on a demotion waits for it, so a hook that hangs mustn't
# hold that up.
hook() {
	[ -x "fluxer-ha/hooks/$1" ] || return 0
	timeout -k 5 "$(envnum FLUXER_HA_HOOK_TIMEOUT_SECONDS 60)" "fluxer-ha/hooks/$1" "$SITE" || alert "hook $1 failed or timed out (exit $?)"
}

# The gateway's state is good only on the site that receives the API's
# messages, and each site has its own NATS (lab F43, F47):
#   - its guild processes load once and then change only through dispatches,
#     and never stop when idle, so on a spare they go stale;
#   - it fetches the rollout config from the API once, 2 s after it starts,
#     and never again; the spare has no API, so it never gets it.
# So the gateway restarts when this site stops being primary (it has no
# clients then), and, after a promotion, once the API is healthy if its last
# word on that config was a failed fetch.
gateway_restart() {
	# FLUXER_HA_GATEWAY_RESTARTS=off: for reproducing F43 in a test only.
	[ "$(envget FLUXER_HA_GATEWAY_RESTARTS)" != off ] || { log "NOT restarting the gateway ($1): FLUXER_HA_GATEWAY_RESTARTS=off"; return 0; }
	log "restarting the gateway: $1"
	dc restart -t 10 gateway >/dev/null 2>&1 || alert "gateway restart failed ($1)"
}
# True if, since the gateway last started (OTP's "started_at:" boot report),
# its rollout-config fetch failed and no push has replaced it. A successful
# fetch of the same config as the defaults logs nothing, hence this shape.
gateway_config_missing() {
	dc logs --no-log-prefix --tail 5000 gateway 2>/dev/null |
		awk '/started_at:/ {f = 0; u = 0} /Gateway rollout config failed to fetch/ {f = 1; u = 0} /Gateway rollout config updated/ {u = 1} END {exit !(f && !u)}'
}
api_healthy() {
	id=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=api" | head -n 1)
	[ -n "$id" ] && [ "$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null)" = healthy ]
}

# What's running comes from Docker by Compose label, not `docker compose ps`,
# so it still works when the compose files don't parse.
running_services() {
	docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Label "com.docker.compose.service"}}'
}
stop_services() {
	t=$1; shift
	ids=$(for s in "$@"; do
		docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$s"
	done)
	# shellcheck disable=SC2086
	[ -z "$ids" ] || docker stop -t "$t" $ids >/dev/null
}
# all, some or none; unknown if Docker doesn't answer (then nothing starts).
cold_state() {
	r=$(running_services 2>/dev/null) || { echo unknown; return; }
	n=0; m=0
	for s in $COLD; do
		m=$((m + 1))
		say "$r" | grep -qx "$s" && n=$((n + 1))
	done
	if [ "$n" -eq "$m" ]; then echo all; elif [ "$n" -eq 0 ]; then echo none; else echo some; fi
}

# The snowflake clock gate:
#   - chrony offset under 100 ms
#   - now is more than 1 s past the newest persisted message ID's timestamp
# IDs are (ms - 1420070400000) << 22 (fluxer_snowflakes/src/generator.rs).
clock_gate() {
	offset=$(chronyc tracking 2>/dev/null | awk '/^System time/ {print $4}')
	[ -n "$offset" ] && awk -v o="$offset" 'BEGIN { exit !(o < 0.1) }' || { log "clock gate: offset=${offset:-unknown}"; return 1; }
	# No KV table yet (a fresh database) means no messages yet.
	kv_exists=$(docker compose exec -T postgres psql -U postgres -d "$PGDB" -Atq -c \
		"select to_regclass('$KV_TABLE') is not null" </dev/null 2>/dev/null) || return 1
	if [ "$kv_exists" = t ]; then
		newest=$(docker compose exec -T postgres psql -U postgres -d "$PGDB" -Atq -c \
			"select coalesce(((max((row_data->'message_id'->>'value')::bigint) >> 22) + 1420070400000), 0)
			 from $KV_TABLE where table_name = 'messages' and row_data->'message_id'->>'value' ~ '^[0-9]+\$'" </dev/null 2>/dev/null) || return 1
	else
		newest=0
	fi
	now_ms=$(($(date +%s) * 1000))
	[ $((now_ms - newest)) -gt 1000 ] || { log "clock gate: newest message ${newest} too close to now ${now_ms}"; return 1; }
}

start_cold() {
	gate_started=$(date +%s)
	until clock_gate; do
		[ $(( $(date +%s) - gate_started )) -lt 30 ] || { alert "clock gate still failing after 30s; NOT starting the app tier"; gate_started=$(date +%s); }
		is_primary || return 1
		sleep 1
	done
	log "primary: starting cold tier"
	# shellcheck disable=SC2086
	dc up -d --no-deps $COLD
	gw_check=1 gw_check_since=$(date +%s)
	hook on-primary
}

stop_cold() {
	log "not primary: stopping cold tier"
	# The edge first, so no new requests arrive while the rest stops.
	stop_services 5 edge
	# shellcheck disable=SC2086
	stop_services 10 $COLD
	gateway_restart "this site was demoted"
	gw_clean=1
	hook on-replica
}

# Stop the cold tier only after MISS_LIMIT consecutive "not primary" polls
# (about 6 s), so one slow REST reply doesn't cause an outage. Safe: once
# Patroni demotes Postgres it is read-only.
MISS_LIMIT=3
misses=0
last_warm=0
last_dns=0
last_state=""
gw_check=0 gw_check_since=0
gw_clean=0
log "starting"
while true; do
	now=$(date +%s)
	if [ $((now - last_warm)) -ge $WARM_EVERY ]; then
		# shellcheck disable=SC2086
		dc up -d --no-deps --no-recreate $WARM >/dev/null 2>&1 || log "warm tier check failed"
		last_warm=$now
	fi

	if is_primary; then
		misses=0
		state=primary
		# DNS first and in the background, so propagation overlaps the cold
		# start; re-asserted every DNS_EVERY seconds.
		if [ "$last_state" != primary ] || [ $((now - last_dns)) -ge $DNS_EVERY ]; then
			./fluxer-ha/dns-failover.sh >>"$STATE_DIR/dns.log" 2>&1 &
			last_dns=$now
		fi
		case $(cold_state) in
			all)
				if [ -z "$last_state" ] && gateway_config_missing; then
					log "WARNING: the gateway never loaded the rollout config (it started before the API answered; an upstream issue). Restart it at a quiet time: docker compose restart gateway"
				fi
				;;
			unknown) log "docker ps failed; leaving the cold tier as it is" ;;
			*) start_cold || true ;;
		esac
		gw_clean=0
		if [ "$gw_check" = 1 ]; then
			if api_healthy; then
				gw_check=0
				! gateway_config_missing || gateway_restart "promoted, and it has no rollout config (the API wasn't up when it started)"
			elif [ $((now - gw_check_since)) -ge 300 ]; then
				gw_check=0; alert "the API isn't healthy 5 min after the promotion; the gateway wasn't restarted for its config"
			fi
		fi
	else
		misses=$((misses + 1))
		state=not-primary
		gw_check=0
		# Unknown also stops: the fail-closed direction.
		if [ "$misses" -ge "$MISS_LIMIT" ]; then
			if [ "$(cold_state)" != none ]; then stop_cold
			# Started as the spare (a reboot, or the controller was down at the
			# demotion): its gateway may still hold state from being primary.
			elif [ "$gw_clean" = 0 ]; then gateway_restart "this site isn't primary"; gw_clean=1
			fi
		fi
	fi

	if [ "$state" != "$last_state" ]; then
		[ -z "$last_state" ] || alert "role changed: $last_state -> $state"
		last_state=$state
	fi
	sleep $POLL
done
