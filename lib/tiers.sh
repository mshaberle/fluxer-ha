# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=sh
#
# Every service in the merged Compose config belongs to exactly one tier.
# rollout.sh refuses to run if a service is missing here (an upstream release
# that adds one), so this list can't silently fall out of date.
#
#   COLD   the primary only; the controller starts and stops them
#   WARM   both sites; no database writes at start-up, no inbound traffic
#   DATA   both sites, always; the controller never touches them
#          (in rollout order: etcd and Postgres first, then the rest)
#   ONCE   one-shot jobs, left to `docker compose up`
#
# Sourcing this file keeps only the services the current configuration
# defines, so a release that drops or renames a service doesn't make the
# controller ask Compose for one that doesn't exist (lab, 2026-10-29: a list
# naming the -shard services that release 2026.1028 merged kept the app tier
# from starting). Without a configuration that parses, the full lists stay.
COLD_ALL="edge livekit api worker push app-proxy admin users messages"
WARM_ALL="gateway media-proxy static-proxy snowflakes gifs unfurl"
DATA_ALL="etcd postgres valkey nats meilisearch seaweedfs valkey-role-link filer-sync s3-mirror"
ONCE_ALL="seaweedfs-init"

# tiers_load: keep the services the configuration defines. Sets SERVICES to
# that list (one per line). Returns 1, changing nothing, if it doesn't parse.
tiers_load() {
	tl_svcs=$(docker compose --profile app config --services 2>/dev/null) || return 1
	[ -n "$tl_svcs" ] || return 1
	SERVICES=$tl_svcs
	COLD=$(tiers_keep "$COLD_ALL"); WARM=$(tiers_keep "$WARM_ALL")
	DATA=$(tiers_keep "$DATA_ALL"); ONCE=$(tiers_keep "$ONCE_ALL")
}
tiers_keep() {
	tk_out=
	for tk_s in $1; do printf '%s\n' "$SERVICES" | grep -qx "$tk_s" && tk_out="$tk_out $tk_s"; done
	printf '%s\n' "${tk_out# }"
}
# Services the configuration defines that no tier names (a new upstream service).
tiers_unknown() {
	printf '%s\n' "$SERVICES" | grep -vxF "$(printf '%s\n' $COLD_ALL $WARM_ALL $DATA_ALL $ONCE_ALL)" || true
}
# Containers of this project whose service the configuration no longer
# defines: what an upgrade left behind (lab, 2026-10-29: an old
# snowflakes-shard kept running next to the new snowflakes, both worker 1).
tiers_orphans() {
	docker ps -a --filter "label=com.docker.compose.project=${PROJECT:-fluxer}" --format '{{.Label "com.docker.compose.service"}}' |
		sort -u | grep -vxF "$SERVICES" || true
}

SERVICES=$(printf '%s\n' $COLD_ALL $WARM_ALL $DATA_ALL $ONCE_ALL)
COLD=$COLD_ALL WARM=$WARM_ALL DATA=$DATA_ALL ONCE=$ONCE_ALL
tiers_load || true
