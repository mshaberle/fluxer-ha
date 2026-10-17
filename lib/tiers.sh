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
COLD="edge livekit api worker push app-proxy admin users users-shard messages messages-shard"
WARM="gateway media-proxy static-proxy snowflakes snowflakes-shard gifs gifs-shard unfurl unfurl-shard"
DATA="etcd postgres valkey nats meilisearch seaweedfs valkey-role-link filer-sync s3-mirror"
ONCE="seaweedfs-init"
