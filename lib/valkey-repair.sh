# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=sh
#
# Valkey that can't load its append-only file (lab F49). Sourced by
# ha-health.sh, which runs every 30 s on both sites; acts at most once every
# 10 minutes.
#
# A power cut can leave a damaged record in the append-only file, or damage
# its base RDB file. Valkey recovers a file that only ends early
# (aof-load-truncated), but not those, and then restarts in a loop: this site
# has no Valkey, the spare's health check fails, and failback waits. The
# repair keeps the damaged files for examination, in
# fluxer-ha/errors/valkey-<time>/ with Valkey's log, then:
#   - on the spare: starts Valkey empty. It's a replica, so it copies
#     everything from the primary's (valkey-role-link sets REPLICAOF).
#   - anywhere else: a damaged .aof file is cut at the damaged record with
#     valkey-check-aof --fix (what upstream's error message suggests), which
#     keeps everything before it. If that isn't enough, or the base RDB is the
#     damaged one, Valkey starts empty: service rather than downtime.
# Either way it alerts. It never acts while Valkey runs, or on any other error
# (not, for example, on running out of memory).
# What Valkey logs for a damaged file (lab, Valkey 9.1: the .aof record, and the base RDB).
VALKEY_DAMAGED='Bad file format reading the append only file|Unexpected end of file reading the append only file|Internal error in RDB reading|Wrong signature trying to load DB'

# valkey_up <container>: true once it runs and answers PING (up to 20 s).
valkey_up() {
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		sleep 2
		[ "$(docker inspect -f '{{.State.Status}}/{{.State.Restarting}}' "$1" 2>/dev/null)" = running/false ] &&
			docker exec "$1" valkey-cli PING 2>/dev/null | grep -q PONG && return 0
	done
	return 1
}

valkey_repair() {
	vcid=$(docker compose ps -aq valkey 2>/dev/null | head -n 1)
	[ -n "$vcid" ] || return 0
	case $(docker inspect -f '{{.State.Status}}/{{.State.Restarting}}' "$vcid" 2>/dev/null) in
		running/false | "") return 0 ;;
	esac
	docker logs --tail 40 "$vcid" 2>&1 | grep -qE "$VALKEY_DAMAGED" || return 0
	vlast=$(cat "$STATE_DIR/valkey-repair-at" 2>/dev/null || echo 0)
	[ $(( $(date +%s) - vlast )) -ge 600 ] || return 0
	date +%s >"$STATE_DIR/valkey-repair-at"

	vts=$(date -u +%Y%m%dT%H%M%SZ)
	vout=$(pwd)/fluxer-ha/errors/valkey-$vts
	mkdir -p "$vout" && chmod 700 "$(pwd)/fluxer-ha/errors" "$vout"
	vvol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$vcid")
	vimg=$(docker inspect -f '{{.Config.Image}}' "$vcid")
	vutil=$(envget FLUXER_HA_UTIL_IMAGE); vutil=${vutil:-alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6}
	docker logs --tail 200 "$vcid" >"$vout/valkey.log" 2>&1 || true
	if curl -fsS -m 2 -o /dev/null http://127.0.0.1:8008/replica 2>/dev/null; then vrole=spare; else vrole=primary; fi

	docker compose stop valkey >/dev/null 2>&1 || true
	# The damaged files, readable by you (Valkey's are its own uid's, mode 600).
	docker run --rm -v "$vvol:/data" -v "$vout:/out" "$vutil" \
		sh -c "cp -a /data/appendonlydir /out/ && { [ ! -f /data/dump.rdb ] || cp -a /data/dump.rdb /out/; } && chown -R $(id -u):$(id -g) /out" >/dev/null 2>&1 ||
		{ alert "Valkey can't load its append-only file and copying it to $vout failed; not repairing (look at docker compose logs valkey)"; return 0; }
	# The .aof file Valkey names in its error, as in "...append only file
	# appendonly.aof.3.incr.aof:". Not an RDB file: valkey-check-aof "fixes"
	# a damaged base RDB by cutting it to 0 bytes (lab).
	vbad=$(docker logs --tail 40 "$vcid" 2>&1 | sed -n 's/.*reading the append only file \([A-Za-z0-9._-]*\.aof\)[^A-Za-z0-9._-].*/\1/p' | tail -n 1)
	vok=0
	if [ "$vrole" = primary ] && [ -n "$vbad" ]; then
		# That one file, cut at its damaged record. (Pointed at the manifest,
		# valkey-check-aof 9.1 read the RDB base file as an append-only file and
		# fixed nothing: lab.)
		docker run --rm -v "$vvol:/data" --entrypoint sh "$vimg" \
			-c "yes | valkey-check-aof --fix /data/appendonlydir/$vbad" >"$vout/valkey-check-aof.txt" 2>&1 || true
		docker compose up -d --no-deps valkey >/dev/null 2>&1 || true
		if valkey_up "$vcid"; then
			vok=1
			how="repaired with valkey-check-aof --fix on $vbad (what came after the damaged record is lost; the full original is kept)"
		else
			docker compose stop valkey >/dev/null 2>&1 || true
		fi
	fi
	if [ "$vok" = 0 ]; then
		# Service rather than downtime (the owner's choice): Valkey starts
		# empty, and the damaged original is kept.
		docker run --rm -v "$vvol:/data" "$vutil" rm -rf /data/appendonlydir /data/dump.rdb >/dev/null 2>&1
		docker compose up -d --no-deps valkey >/dev/null 2>&1 || true
		if [ "$vrole" = spare ]; then
			how="started empty; it copies everything from the primary's Valkey"
		elif [ -n "$vbad" ]; then
			how="valkey-check-aof couldn't repair it, so Valkey STARTED EMPTY on this primary: what it held is gone here (the damaged original is kept)"
		else
			how="its base RDB file is damaged, so Valkey STARTED EMPTY on this primary: what it held is gone here (the damaged original is kept)"
		fi
		valkey_up "$vcid" || how="$how. VALKEY STILL ISN'T RUNNING: look at docker compose logs valkey"
	fi
	{
		echo "Valkey on $(envget FLUXER_HA_SITE) ($vrole) couldn't load its append-only file: $vts"
		echo "Repair: $how."
		echo "appendonlydir/  the damaged files, as Valkey left them (and dump.rdb, if there was one)"
		echo "valkey.log      Valkey's last 200 lines before the repair"
		[ ! -f "$vout/valkey-check-aof.txt" ] || echo "valkey-check-aof.txt  what the fix reported"
		echo "See docs/operations.md, \"Valkey won't start\"."
	} >"$vout/README.txt"
	alert "Valkey couldn't load its append-only file (damaged, probably by a power cut); $how. Damaged files kept in $vout"
}
