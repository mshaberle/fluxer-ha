#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Automatic failback. Runs every 60 s on BOTH sites (fluxer-ha-failback.timer)
# and does nothing except on the PREFERRED site (FLUXER_HA_PREFERRED_SITE)
# while that site is the replica. See docs/architecture.md, "Failback".
#
# Moves the primary back to the preferred site with a planned Patroni
# switchover once that site has passed every check below CONTINUOUSLY for the
# required window (FLUXER_HA_FAILBACK_STABLE_SECONDS, default 1 h):
#   - it is a running replica and the synchronous standby, so the switchover
#     is zero-loss
#   - ha-health.sh passes (etcd 3/3, Valkey link, media mirror, controller,
#     clock, identical fluxer-ha/.env.shared, public DNS on the peer)
#   - the peer is the primary
#   - no host reboot, Postgres restart, timeline change or Patroni pause
# Then, before switching:
#   - the local hour is inside FLUXER_HA_FAILBACK_HOURS, if set
#   - no background jobs are in flight on the primary's JOBS stream (R1 per
#     site, so it stays behind at a switchover), waiting up to JOBS_WAIT
# After switching, it requires this site to serve /api/_health over HTTPS on
# its own port 443 (the bundled edge, or your reverse proxy in front of it),
# and public DNS to point here (unless FLUXER_HA_DNS_PROVIDER=none), within
# VERIFY seconds. If not, it
# switches back to the peer and holds off: the next attempt comes after RETRY
# seconds (default 6 h), doubling with each consecutive failure up to
# MAX_RETRY (default 7 days), and only after a fresh stability window. No
# human is needed. A success resets the count.
#
# Operator hold: an EMPTY $LATCH (`touch` it) stops automatic failback until
# it's removed. A latch this script writes holds `at=` and `failures=` and
# expires on its own.
#
# Anti-flap: if this site loses the primary role within RELAPSE seconds of an
# automatic failback, the next required window doubles, capped at MAX.
#
# This script never promotes, demotes or fences anything itself. It asks
# Patroni for a switchover; the controllers then move the app tier and DNS.
set -u
HA_NAME=failback
. "$(dirname "$0")/common.sh"

PREFERRED=$(envget FLUXER_HA_PREFERRED_SITE)
PEER=$(envget FLUXER_HA_PEER_SITE)
PEER_WG=$(envget FLUXER_HA_PEER_WG_IP)
DNS_NAME=$(envget FLUXER_HA_DNS_NAME)
# The HTTPS check uses the name the certificate is for (FLUXER_DOMAIN); the DNS
# check uses the record that moves (FLUXER_HA_DNS_NAME). Usually the same.
TLS_NAME=$(envget FLUXER_DOMAIN); TLS_NAME=${TLS_NAME:-$DNS_NAME}
PUBLIC_IPV4=$(envget FLUXER_HA_PUBLIC_IPV4)
DNS_PROVIDER=$(envget FLUXER_HA_DNS_PROVIDER); DNS_PROVIDER=${DNS_PROVIDER:-none}
RESOLVER=$(envget FLUXER_HA_DNS_CHECK_RESOLVER); RESOLVER=${RESOLVER:-1.1.1.1}
KV_TABLE=$(envget FLUXER_POSTGRES_KV_TABLE); KV_TABLE=${KV_TABLE:-fluxer_kv}
PGDB=$(envget FLUXER_POSTGRES_DATABASE); PGDB=${PGDB:-fluxer}
ENABLED=$(envnum FLUXER_HA_FAILBACK_ENABLED true)
STABLE=$(envnum FLUXER_HA_FAILBACK_STABLE_SECONDS 3600)
MAX=$(envnum FLUXER_HA_FAILBACK_MAX_STABLE_SECONDS 86400)
RELAPSE=$(envnum FLUXER_HA_FAILBACK_RELAPSE_SECONDS 86400)
JOBS_WAIT=$(envnum FLUXER_HA_FAILBACK_JOBS_WAIT_SECONDS 1800)
HOURS=$(envget FLUXER_HA_FAILBACK_HOURS)
RETRY=$(envnum FLUXER_HA_FAILBACK_RETRY_SECONDS 21600)
MAX_RETRY=$(envnum FLUXER_HA_FAILBACK_MAX_RETRY_SECONDS 604800)
VERIFY=600
ROLLBACK_WAIT=300

STATE=$STATE_DIR/failback.state
LATCH=$STATE_DIR/failback.latched

# State is key=value lines, so it survives reboots and controller restarts.
sget() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1; }
sset() { { grep -v "^$1=" "$STATE" 2>/dev/null || true; echo "$1=$2"; } >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"; }
reset() {
	[ -z "$(sget since)" ] || log "stability reset: $1"
	sset since ""
	sset jobs_since ""
}
# POST a Patroni switchover to the given node and print the HTTP code.
# Patroni 4.0 answers 200 once the switchover has completed.
switchover() {
	out=$(patroni_post "$1" switchover "{\"leader\":\"$2\",\"candidate\":\"$3\"}" 90)
	code=$(say "$out" | tail -n 1)
	[ "$code" = 200 ] || log "switchover $2 -> $3 answered $code: $(say "$out" | head -n 1)" >&2
	say "$code"
}
in_hours() {
	[ -n "$HOURS" ] || return 0
	from=${HOURS%-*}; to=${HOURS#*-}; h=$(date +%H | sed 's/^0//')
	if [ "$from" -le "$to" ]; then
		[ "$h" -ge "$from" ] && [ "$h" -lt "$to" ]
	else
		[ "$h" -ge "$from" ] || [ "$h" -lt "$to" ]
	fi
}

[ "$SITE" = "$PREFERRED" ] && [ "$ENABLED" = true ] || exit 0
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/failback.lock"
flock -n 9 || exit 0
now=$(date +%s)

# --- 1. Track the local role -------------------------------------------------
if api 127.0.0.1 primary; then
	[ "$(sget role)" = primary ] || sset role primary
	[ -z "$(sget since)" ] || reset "this site is the primary"
	exit 0
fi
api 127.0.0.1 replica || { reset "not a running replica"; exit 0; }

if [ "$(sget role)" != replica ]; then
	# Just became the replica, or came back from an outage as one.
	window=$STABLE
	last=$(sget last_failback)
	if [ -n "$last" ] && [ $((now - last)) -lt "$RELAPSE" ]; then
		prev=$(sget last_window)
		window=$(( ${prev:-$STABLE} * 2 ))
		[ "$window" -le "$MAX" ] || window=$MAX
		alert "replica again $(( (now - last) / 60 )) min after the last automatic failback; the next one needs $((window / 60)) min of stability"
	fi
	sset window "$window"
	sset role replica
	reset "became the replica"
fi

# An operator hold (empty latch), or a back-off after a failed verification
# (step 5), which expires on its own.
if [ -e "$LATCH" ]; then
	at=$(sed -n 's/^at=//p' "$LATCH")
	failures=$(sed -n 's/^failures=//p' "$LATCH")
	[ -n "$at" ] && [ -n "$failures" ] || exit 0
	hold=$RETRY
	n=1
	while [ "$n" -lt "$failures" ] && [ "$hold" -lt "$MAX_RETRY" ]; do hold=$((hold * 2)); n=$((n + 1)); done
	[ "$hold" -le "$MAX_RETRY" ] || hold=$MAX_RETRY
	[ $((now - at)) -ge "$hold" ] || exit 0
	rm -f "$LATCH"
	alert "automatic failback: retrying after failed attempt $failures (held $((hold / 3600)) h); a fresh stability window starts now"
fi

# --- 2. Stability, every run --------------------------------------------------
pj=$(curl -fsS -m 2 http://127.0.0.1:8008/patroni) || { reset "Patroni API unreachable"; exit 0; }
pj=$(echo "$pj" | tr -d ' \n')
case $pj in *'"pause":true'*) reset "Patroni is paused"; exit 0 ;; esac
tl=$(echo "$pj" | sed -n 's/.*"timeline":\([0-9]*\).*/\1/p')
pm=$(echo "$pj" | sed -n 's/.*"postmaster_start_time":"\([^"]*\)".*/\1/p')
# Catches a reboot, Postgres restart or timeline change that happened between
# two runs. /patroni reports both fields on a replica (lab, Patroni 4.1.5).
fp="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)|$pm|$tl"

if ! why=$(HA_HEALTH_NO_PING=1 ./fluxer-ha/ha-health.sh 2>&1); then
	reset "$(echo "$why" | tail -n 1)"
	exit 0
fi
api "$PEER_WG" primary || { reset "peer $PEER is not the primary"; exit 0; }

since=$(sget since)
if [ -z "$since" ] || [ "$(sget fp)" != "$fp" ]; then
	[ -z "$since" ] || log "stability reset: reboot, Postgres restart or timeline change"
	sset since "$now"
	sset fp "$fp"
	sset jobs_since ""
	window=$(sget window)
	log "stable; automatic failback in $(( ${window:-$STABLE} / 60 )) min if nothing changes"
	exit 0
fi
window=$(sget window); window=${window:-$STABLE}
[ $((now - since)) -ge "$window" ] || exit 0

# --- 3. Gates that delay the switchover without resetting stability --------
in_hours || exit 0

# Jobs enqueued since the current primary was promoted sit on ITS JOBS stream,
# which doesn't move at a switchover. The job ledger is in Postgres, so this
# replica can see them (jobs_active rows are deleted when a job finishes:
# fluxer_api/src/api/jobs/JobLedgerRepository.ts:156 and :210). Jobs created
# with skipLedger (mention fan-out, crossposts) aren't counted.
# GET /history lists timeline switches with ISO timestamps, the last being
# the current primary's promotion, and the ledger's created_at is stored as
# {"value": ISO, "__fluxer_type": "date"} (PostgresJobLedgerExpiry.ts:60;
# both checked in the lab, Patroni 4.1.5).
#
# /history mirrors etcd's history key, so treat it as untrusted (docs/security.md S4): only
# a strict ISO-8601 timestamp is accepted, and it reaches SQL as a psql
# variable (:'promoted', quoted by psql), sent on stdin because psql doesn't
# expand variables in -c.
promoted=$(curl -fsS -m 2 http://127.0.0.1:8008/history | tr -d ' \n' |
	grep -o '"[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[^"]*"' | tail -n 1 | tr -d '"')
echo "$promoted" | grep -Eqx '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}(:?[0-9]{2})?)' || promoted=""
echo "$KV_TABLE" | grep -Eqx '[a-z_][a-z0-9_]{0,62}' || { reset "FLUXER_POSTGRES_KV_TABLE is not a plain table name"; exit 1; }
inflight=unknown
if [ -n "$promoted" ]; then
	inflight=$(printf '%s\n' "select count(*) from $KV_TABLE where table_name = 'jobs_active'
		 and (expires_at is null or expires_at > now())
		 and (row_data->'created_at'->>'value')::timestamptz >= :'promoted'::timestamptz;" |
		docker compose exec -T postgres psql -U postgres -d "$PGDB" -Atq -v ON_ERROR_STOP=1 -v promoted="$promoted" 2>/dev/null) || inflight=unknown
fi
if [ "$inflight" != 0 ]; then
	js=$(sget jobs_since)
	if [ -z "$js" ]; then
		sset jobs_since "$now"
		log "waiting for $inflight in-flight job(s) on $PEER (up to $((JOBS_WAIT / 60)) min)"
		exit 0
	fi
	[ $((now - js)) -ge "$JOBS_WAIT" ] || exit 0
	alert "switching back with $inflight job(s) still in flight on $PEER; they won't run. Check the job ledger (docs/operations.md, "Jobs left behind")."
fi

# --- 4. Switch over -----------------------------------------------------------
alert "automatic failback: $SITE stable for $(( (now - since) / 60 )) min; switching the primary over from $PEER"
code=$(switchover "$PEER_WG" "$PEER" "$SITE")
if [ "$code" != 200 ]; then
	alert "automatic failback: Patroni refused the switchover ($code); waiting a full window before retrying"
	reset "switchover refused"
	exit 1
fi
sset last_failback "$now"
sset last_window "$window"
sset role primary
sset since ""
sset jobs_since ""

# --- 5. Verify: this site serves users and public DNS points here ------------
started=$(date +%s)
while [ $(( $(date +%s) - started )) -lt "$VERIFY" ]; do
	# Public DNS is checked only when the HA layer manages DNS.
	if api 127.0.0.1 primary &&
		curl -fsS -m 5 -o /dev/null --resolve "$TLS_NAME:443:127.0.0.1" "https://$TLS_NAME/api/_health" &&
		{ [ "$DNS_PROVIDER" = none ] || [ "$(dig +short A "$DNS_NAME" @"$RESOLVER" | tail -n 1)" = "$PUBLIC_IPV4" ]; }; then
		alert "automatic failback complete: $SITE serving $(( $(date +%s) - started )) s after the switchover"
		sset failures 0
		exit 0
	fi
	sleep 10
done

if ! api 127.0.0.1 primary; then
	# Patroni already moved the primary away again. Step 1 doubles the next window.
	alert "automatic failback: $SITE lost the primary role during verification"
	exit 1
fi

# Primary here but not serving: something the automation can't diagnose.
# Go back to the peer, which served fine, and back off before trying again.
failures=$(( $(sget failures | grep -E '^[0-9]+$' || echo 0) + 1 ))
sset failures "$failures"
printf 'at=%s\nfailures=%s\nreason=%s did not serve within %ss of an automatic failback\n' \
	"$(date +%s)" "$failures" "$SITE" "$VERIFY" >"$LATCH"
alert "automatic failback FAILED (attempt $failures): $SITE not serving after ${VERIFY}s; switching back to $PEER. It retries on its own after a back-off."
waited=0
until api "$PEER_WG" sync || [ "$waited" -ge "$ROLLBACK_WAIT" ]; do sleep 5; waited=$((waited + 5)); done
code=$(switchover 127.0.0.1 "$SITE" "$PEER")
if [ "$code" = 200 ]; then
	# Not a relapse: once the back-off expires, a fresh base window applies.
	sset role replica
	sset window "$STABLE"
	alert "rolled back: $PEER is the primary again"
else
	alert "ROLLBACK FAILED ($code): $SITE is the primary but not serving. See docs/operations.md, "Failback rolled back but failed"."
fi
exit 1
