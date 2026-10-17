#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The s3-mirror loop (compose/ha.compose.yml runs it in the rclone image, as
# uid 65534, read-only but for /state and /tmp). On the replica only:
#   (1) the first time this node becomes a replica, push every object that
#       exists only here up to the new primary, which recovers uploads
#       stranded by a failover however long the outage lasted;
#   (2) then every INTERVAL seconds (default 1 h), reconcile with an exact
#       mirror from the primary.
# filer-sync does the second-by-second copying; this is the safety net for
# anything it missed, and the first full copy on a new replica.
#
# Nothing here has a time limit: a long first copy, or a large file on a slow
# link, takes as long as it takes. What ends a run is a lack of PROGRESS: an
# rclone run whose counters (bytes, files, checks, objects listed) haven't
# moved for STALL seconds is killed (lab F50: a read hung on a dead connection
# and rclone's own --timeout didn't end it).
#
# An object that can't be read (lab F52: metadata kept, data lost in a reset;
# reading it hung rather than failing) must not stop the rest: a run that
# stalls or fails is followed by a search for the objects that won't copy.
# Each is tried alone, and one that makes no progress for OBJECT_STALL
# seconds, or fails, is skipped from then on. Its details go to /state/errors/
# (ha-health.sh copies them to fluxer-ha/errors/s3-mirror/ and alerts), and
# each reconcile tries it again. Failover doesn't depend on this mirror, so a
# skipped object never marks the spare unhealthy.
#
# An object the push-back (1) skipped exists only here, so the exact mirror (2)
# would delete it as "not on the primary" (lab, ninth run). The mirror
# excludes those too, which rclone never deletes, and each reconcile tries to
# push them again, never over an object the primary has.
#
# `fluxer-ha rollout` asks for a full sync by writing a time to
# /state/sync-request, and waits for /state/sync-result ("ok <time> ..." or
# "failed <time> <why>"). /state/progress has the current run's counters
# (what, when, rclone's counters; tab-separated).
set -u
STALL=${STALL:-300}              # seconds without progress before a run is killed
OBJECT_STALL=${OBJECT_STALL:-60} # the same, for one object, when looking for the unreadable ones
mkdir -p /state/errors
log() { echo "$(date -u +%FT%TZ) s3-mirror: $*"; }
# A name as an rclone filter rule that matches only itself.
esc() { sed 's/[][*?{}\\]/\\&/g; s#^#/#'; }

# counters <log>: the last progress counters in rclone's JSON log, without the
# fields that change with time alone (elapsed time, speed, ETA).
counters() {
	sed -n 's/.*"stats":{\([^}]*\)}.*/\1/p' "$1" 2>/dev/null | tail -n 1 |
		sed 's/"elapsedTime":[^,]*,//; s/"eta":[^,]*,//; s/"speed":[^,]*,//; s/"transferTime":[^,]*,//'
}

# watched <stall> <label> <rclone args...>: runs rclone; kills it once its
# counters haven't moved for <stall> seconds (exit 124). Its log is /tmp/rclone.log.
watched() {
	wstall=$1; wlabel=$2; shift 2
	: >/tmp/rclone.log
	rclone "$@" --stats 10s --stats-log-level NOTICE --log-level NOTICE --use-json-log --log-file /tmp/rclone.log &
	wpid=$!
	wlast=; wsince=$(date +%s)
	while kill -0 "$wpid" 2>/dev/null; do
		sleep 5
		wnow=$(counters /tmp/rclone.log)
		if [ "$wnow" != "$wlast" ]; then
			wlast=$wnow; wsince=$(date +%s)
			printf '%s\t%s\t%s\n' "$wlabel" "$(date +%s)" "$wnow" >/state/progress
		elif [ $(( $(date +%s) - wsince )) -ge "$wstall" ]; then
			kill -9 "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
			log "$wlabel: no progress for ${wstall}s; killed"
			return 124
		fi
	done
	wait "$wpid"
}
# What rclone said, other than its progress lines.
said() { grep -v '"stats":' /tmp/rclone.log | tail -n 5; }

# run_one <src> <dst> <bucket> <copy|sync>: one rclone run, skipping the known unreadable.
run_one() {
	skip=/state/unreadable-$1-$3.txt; touch "$skip" "/state/unreadable-local-$3.txt"
	# The mirror from the primary also leaves alone what the push-back couldn't
	# push: it exists only here (excluded names are never deleted).
	if [ "$4" = sync ]; then cat "$skip" "/state/unreadable-local-$3.txt"; else cat "$skip"; fi | esc >/tmp/exclude.txt
	if [ "$4" = copy ]; then
		watched "$STALL" "copy $1:$3 -> $2" copy "$1:$3" "$2:$3" --ignore-existing --fast-list --s3-no-check-bucket --exclude-from /tmp/exclude.txt
	else
		watched "$STALL" "sync $1:$3 -> $2" sync "$1:$3" "$2:$3" --fast-list --max-delete "$MAX_DELETE" --s3-no-check-bucket --exclude-from /tmp/exclude.txt
	fi
}

# keep <src> <bucket> <object> <why>: the record of an object skipped as unreadable.
keep() {
	# One folder per finding, never reused: the name is cut to 80 characters,
	# so a hash of the full name keeps two long ones found in the same second apart.
	d=/state/errors/$(date -u +%Y%m%dT%H%M%SZ)-$1-$2-$(printf '%s' "$3" | tr '/' '_' | cut -c1-80)-$(printf '%s' "$3" | md5sum | cut -c1-8)
	mkdir -p "$d"
	{
		echo "bucket:  $2"
		echo "object:  $3"
		if [ "$1" = primary ]; then echo "read from: the primary ($PEER)"; else echo "read from: this site"; fi
		echo "found:   $(date -u +%FT%TZ)"
		echo "skipped by s3-mirror from now on; tried again at each reconcile"
		echo "rclone, trying it alone (killed after ${OBJECT_STALL}s without progress):"
		echo "$4"
	} >"$d/README.txt"
	# SeaweedFS's own record of it (chunks and their file IDs), from that site's filer.
	if [ "$1" = primary ]; then f=$PEER; else f=seaweedfs; fi
	wget -q -T 10 -O "$d/filer-metadata.json" "http://$f:8888/buckets/$2/$3?metadata=true" 2>/dev/null || rm -f "$d/filer-metadata.json"
}

# find_unreadable <src> <dst> <bucket> <copy|sync>: of what dst lacks, the objects that won't copy.
find_unreadable() {
	skip=/state/unreadable-$1-$3.txt; touch "$skip"
	# Sizes and names only: listing never reads an object's data.
	rm -f /tmp/missing /tmp/differ
	watched "$STALL" "check $1:$3 -> $2" check "$1:$3" "$2:$3" --one-way --size-only --fast-list --s3-no-check-bucket \
		--missing-on-dst /tmp/missing --differ /tmp/differ
	# Even listing made no progress: the link, not an object.
	[ $? != 124 ] || return 124
	# Not the ones already skipped. (busybox grep -v with an EMPTY pattern file
	# drops every line, so filter only when there's something to filter.)
	cat /tmp/missing /tmp/differ 2>/dev/null >/tmp/all
	if [ -s "$skip" ]; then grep -vxF -f "$skip" /tmp/all; else cat /tmp/all; fi | head -n 500 >/tmp/candidates
	n=0
	while IFS= read -r o; do
		[ -n "$o" ] || continue
		if ! watched "$OBJECT_STALL" "copy $1:$3/$o" copyto "$1:$3/$o" "$2:$3/$o" --s3-no-check-bucket $(nooverwrite "$4"); then
			out=$(said); [ -n "$out" ] || out="(no progress within ${OBJECT_STALL}s; killed)"
			echo "$o" >>"$skip"; keep "$1" "$3" "$o" "$out"; n=$((n + 1))
			log "UNREADABLE $1:$3/$o: skipped from now on (details in /state/errors)"
		fi
	done </tmp/candidates
	log "$1:$3: $n object(s) newly skipped as unreadable"
}

# nooverwrite <copy|sync>: the push-back never replaces an object the primary has.
nooverwrite() { [ "$1" != copy ] || echo --ignore-existing; }

# recheck <src> <dst> <bucket> <copy|sync>: skipped objects that are readable again, or gone, aren't skipped any more.
recheck() {
	skip=/state/unreadable-$1-$3.txt
	[ -s "$skip" ] || return 0
	: >/tmp/still
	while IFS= read -r o; do
		[ -n "$o" ] || continue
		# No answer isn't "gone": keep it until the listing works.
		if ! there=$(timeout -s KILL 30 rclone lsf "$1:$3/$o" --s3-no-check-bucket 2>/dev/null); then
			echo "$o" >>/tmp/still
		elif [ -z "$there" ]; then
			log "$1:$3/$o is gone; no longer skipped"
		elif watched "$OBJECT_STALL" "copy $1:$3/$o" copyto "$1:$3/$o" "$2:$3/$o" --s3-no-check-bucket $(nooverwrite "$4"); then
			log "$1:$3/$o is readable again and copied; no longer skipped"
		else
			echo "$o" >>/tmp/still
		fi
	done <"$skip"
	cat /tmp/still >"$skip"
}

# mirror <src> <dst> <bucket> <copy|sync>: 0 done, 1 failed, 2 no progress
# (the other site can't be reached: the other buckets wouldn't fare better).
mirror() {
	recheck "$@"
	run_one "$@" && return 0
	log "$1 -> $2 $3: the run stalled or failed; looking for objects that can't be read"
	if find_unreadable "$@"; then
		run_one "$@" && return 0
		rc=$?
	else
		rc=124
	fi
	if [ "$rc" = 124 ]; then
		why="$4 $1:$3 -> $2 made no progress for ${STALL}s (can this site reach the other site's S3?)"
		return 2
	fi
	why="$4 $1:$3 -> $2 failed: $(said | tail -n 1 | cut -c1-300)"
	return 1
}

# answer <ok|failed> <why>: the answer to a sync `fluxer-ha rollout` asked for.
answer() {
	[ -n "$req" ] || return 0
	echo "$1 $req $(date +%s) $2" >/state/sync-result
	[ "$(cat /state/sync-request 2>/dev/null)" != "$req" ] || rm -f /state/sync-request
}

# Roles are checked every 15 s; only the full reconcile waits for INTERVAL.
# (Sleeping INTERVAL between role checks delayed the push-back after a
# failover by up to an hour: lab, 2026-10-15.)
while true; do
	req=$(cat /state/sync-request 2>/dev/null || true)
	if wget -q -T 2 -O /dev/null http://postgres:8008/replica && wget -q -T 2 -O /dev/null "http://$PEER:8008/primary"; then
		if [ "$(cat /state/role 2>/dev/null)" != replica ]; then
			pushed=1
			for b in $BUCKETS; do
				mirror local primary "$b" copy && continue
				rc=$?; [ "$pushed" = 0 ] || first=$why; pushed=0
				[ "$rc" != 2 ] || break
			done
			if [ "$pushed" = 1 ]; then echo replica >/state/role; rm -f /state/last_ok; else answer failed "the push-back to the new primary: $first"; fi
		fi
		if [ "$(cat /state/role 2>/dev/null)" = replica ] && { [ -n "$req" ] ||
			[ $(( $(date +%s) - $(cat /state/last_ok 2>/dev/null || echo 0) )) -ge "$INTERVAL" ]; }; then
			ok=1
			for b in $BUCKETS; do
				# What the push-back couldn't push, tried again first.
				recheck local primary "$b" copy
				mirror primary local "$b" sync && continue
				rc=$?; [ "$ok" = 0 ] || first=$why; ok=0
				[ "$rc" != 2 ] || break
			done
			if [ "$ok" = 1 ]; then date +%s >/state/last_ok; answer ok "all buckets"; else answer failed "$first"; fi
		fi
	elif wget -q -T 2 -O /dev/null http://postgres:8008/primary; then
		echo primary >/state/role
		answer ok "this site is the primary: nothing to mirror"
	fi
	sleep 15
done
