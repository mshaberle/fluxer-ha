#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Applies the current configuration (.env, the compose files, the image lock,
# a rebuilt Patroni image) to THIS site's containers, safely, and only while
# this site is the REPLICA. The controller never applies changes by itself
# (F27), so this is how a change reaches the containers:
#
#   1. edit fluxer-ha/.env.shared / fluxer-ha/.env.site on both sites, fluxer-ha/build-env.sh on both
#   2. on the replica:   fluxer-ha/rollout.sh
#   3. switch over (patronictl switchover, or let failback do it)
#   4. on the new replica (the old primary): fluxer-ha/rollout.sh
#
# On the replica it recreates, one at a time and waiting for each to be
# healthy: etcd (only if the other two members are healthy, so quorum
# survives), Postgres (then waits until it's the synchronous standby again),
# the rest of the data tier, then the warm tier. The cold tier is re-created
# but NOT started; the controller starts it when this site is promoted.
# Last, s3-mirror does a full media sync from the primary, and the rollout
# waits for it with no time limit (lab F51: a copy of a lot of media takes as
# long as it takes). It stops only if the sync makes no progress for
# FLUXER_HA_S3_MIRROR_STALL_SECONDS (default 300), for example because this
# site can't reach the primary. Everything else is rolled out by then, and
# running it again carries on: services already on the new configuration
# aren't recreated, and the copy skips what's already here.
#
#   rollout.sh            do it
#   rollout.sh --dry-run  show what Compose would recreate, change nothing
set -eu
cd "$(dirname "$0")/.."
. ./fluxer-ha/tiers.sh

envget() { sed -n "s/^$1=//p" .env | tail -n 1; }
DRY=${1:-}
EPS=$(envget FLUXER_HA_ETCD_HOSTS)
LOCAL_WG=$(envget FLUXER_HA_LOCAL_WG_IP)
dc() { docker compose --profile app "$@"; }
log() { echo "$(date -u +%FT%TZ) rollout: $*"; }
die() { echo "rollout: $*" >&2; exit 1; }
code() { curl -s -m 2 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true; }

# wait_until <seconds> <what> <command...>
wait_until() {
	limit=$1; what=$2; shift 2
	start=$(date +%s)
	until "$@" >/dev/null 2>&1; do
		[ $(( $(date +%s) - start )) -lt "$limit" ] || die "timed out after ${limit}s waiting for: $what"
		sleep 2
	done
	log "ok: $what ($(( $(date +%s) - start ))s)"
}
healthy() {
	cid=$(dc ps -q "$1")
	[ -n "$cid" ] || return 1
	st=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")
	[ "$st" = healthy ] || [ "$st" = running ]
}
etcd_others_healthy() {
	others=$(echo "$EPS" | tr ',' '\n' | grep -v "^$LOCAL_WG:" | paste -sd, -)
	dc exec -T etcd etcdctl --endpoints="$others" endpoint health </dev/null
}
etcd_local_healthy() { dc exec -T etcd etcdctl --endpoints="$LOCAL_WG:2379" endpoint health </dev/null; }
is_sync() { [ "$(code http://127.0.0.1:8008/sync)" = 200 ]; }
is_replica() { [ "$(code http://127.0.0.1:8008/replica)" = 200 ]; }
# The s3-mirror container reads its script through a bind mount, and fluxer-ha
# updates replace the file, so a running one keeps the old script until it's
# recreated. True when they differ.
mirror_script_stale() {
	mcid=$(dc ps -q s3-mirror)
	[ -n "$mcid" ] && ! docker exec "$mcid" cat /s3-mirror.sh 2>/dev/null | cmp -s - fluxer-ha/s3-mirror.sh
}
running() { cid=$(dc ps -q "$1"); [ -n "$cid" ] && [ "$(docker inspect -f '{{.State.Status}}' "$cid")" = running ]; }
# One line of s3-mirror's progress, from its /state/progress.
mirror_progress() {
	dc exec -T s3-mirror cat /state/progress </dev/null 2>/dev/null | awk -F '\t' '{
		label = $1
		n = split($3, kv, ",")
		for (i = 1; i <= n; i++) { split(kv[i], p, ":"); gsub(/[^a-zA-Z]/, "", p[1]); v[p[1]] = p[2] + 0 }
		printf "%s: %.1f of %.1f MiB, %d of %d files copied, %d checked, %d listed\n", label,
			v["bytes"] / 1048576, v["totalBytes"] / 1048576, v["transfers"], v["totalTransfers"], v["checks"], v["listed"]
	}'
}

# --- Preconditions -----------------------------------------------------------
dc config -q || die "the compose configuration doesn't parse; fix it first"
all=$(dc config --services | sort)
known=$(echo "$COLD $WARM $DATA $ONCE" | tr ' ' '\n' | sort)
unknown=$(echo "$all" | grep -vxF "$known" || true)
[ -z "$unknown" ] || die "services not in fluxer-ha/tiers.sh: $(echo $unknown). Classify them first."

if [ "$DRY" = --dry-run ]; then
	log "dry run. Compose would recreate (or create) on this site:"
	dc up --dry-run -d --no-deps $DATA $WARM 2>&1 | grep -E 'Recreate|Create' | grep -v 'Recreated\|Created' || echo "  nothing in the data and warm tiers"
	! mirror_script_stale || echo "  s3-mirror (its script changed)"
	echo "  and then a full media sync from the primary"
	exit 0
fi

is_replica || die "this site is not a running replica. Switch over first; rollout only runs on the replica."
etcd_others_healthy || die "the other etcd members aren't all healthy; recreating this one could cost quorum"

# --- What this site runs now, for `fluxer-ha rollback` ------------------------
# Before anything here is recreated: the image each service's container runs
# (or, for the stopped cold tier, was created with). The lines read like
# install.sh's records (reference, image ID) plus the registry digest, so an
# image that a prune has removed can be pulled back. The newest 10 are kept.
. ./fluxer-ha/record-images.sh
rec=fluxer-ha/upgrade/rollout-$(date -u +%Y%m%dT%H%M%SZ)
record_images "$rec"
log "recorded what runs now in $rec ($(wc -l <"$rec/images") images)"
ls -1d fluxer-ha/upgrade/rollout-* 2>/dev/null | head -n -10 | xargs -r rm -rf

# --- Data tier, in order -----------------------------------------------------
for s in $DATA; do
	is_replica || die "this site stopped being the replica; stopping here"
	case $s in
		etcd)
			etcd_others_healthy || die "the other etcd members aren't healthy; not touching etcd"
			dc up -d --no-deps etcd
			wait_until 60 "local etcd healthy" etcd_local_healthy
			;;
		postgres)
			dc up -d --no-deps postgres
			wait_until 300 "Postgres streaming as a replica" is_replica
			wait_until 300 "Postgres is the synchronous standby" is_sync
			;;
		s3-mirror) ;; # last, below
		*)
			dc up -d --no-deps "$s"
			wait_until 300 "$s healthy" healthy "$s"
			;;
	esac
done

# --- Warm tier, then the cold tier created but not started -----------------
dc up -d --no-deps $WARM
for s in $WARM; do wait_until 300 "$s healthy" healthy "$s"; done
dc up --no-start --no-deps $COLD

# --- Last: a full media sync from the primary (lab F51) ----------------------
# Waits with no time limit; s3-mirror itself gives up on a run that makes no
# progress, and answers "failed". Objects it skips as unreadable (lab F52)
# don't fail the sync: the rest is complete, and they're in fluxer-ha/errors/.
# A request left by an earlier rollout that was stopped would be answered first.
dc exec -T s3-mirror rm -f /state/sync-request </dev/null 2>/dev/null || true
if mirror_script_stale; then dc up -d --no-deps --force-recreate s3-mirror; else dc up -d --no-deps s3-mirror; fi
wait_until 60 "s3-mirror running" running s3-mirror
req=$(date +%s)
dc exec -T s3-mirror sh -c "echo $req >/state/sync-request" </dev/null
log "s3-mirror: full sync from the primary started. No time limit; it stops only after $(envget FLUXER_HA_S3_MIRROR_STALL_SECONDS | grep . || echo 300)s without progress."
shown=0
while :; do
	res=$(dc exec -T s3-mirror cat /state/sync-result </dev/null 2>/dev/null || true)
	case $res in
		"ok $req "*) break ;;
		"failed $req "*)
			die "the full media sync failed: ${res#failed $req * }
Everything else is rolled out. Fix that, then run fluxer-ha rollout again: it carries on where this one stopped." ;;
	esac
	is_replica || die "this site stopped being the replica during the media sync; everything else is rolled out"
	if [ $(( $(date +%s) - shown )) -ge 30 ]; then
		p=$(mirror_progress); [ -z "$p" ] || log "s3-mirror: $p"
		shown=$(date +%s)
	fi
	sleep 5
done
log "ok: full media sync ($(( $(date +%s) - req ))s; $(dc exec -T s3-mirror sh -c 'cat /state/unreadable-*.txt 2>/dev/null' </dev/null | grep -c . || true) object(s) skipped as unreadable)"
log "done. This site runs the new configuration; switch over to it to roll out the other site."
