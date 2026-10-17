# Architecture

Links into Fluxer's code are pinned to commit [`c0f825ae2`](https://github.com/fluxerapp/fluxer/tree/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd), the version this was built against; the lab has also run it on `51ef7393c`. "Assumption" marks what hasn't been verified.

## Shape

**Active/warm across two sites, with a witness:**
- **Active:** one site, the **primary**, serves users.
- **Warm:** the other, the **spare**, keeps a live copy of every piece of state, plus every service that's safe to run twice, so a takeover only has to start the app tier.
- **The witness:** a third, tiny host that holds the deciding vote, so the two sites never have to guess.

Who's primary is decided by **Patroni** (Postgres high availability), using **etcd** with one member on each site and one on the witness. Everything else **follows** Patroni; nothing else decides.

## Why the database decides

Fluxer keeps its durable state in Postgres (a KV-style table, `fluxer_kv`). The API, the worker and the `users`/`messages` shards apply schema changes when they start ([PostgresKvQueryExecutor.ts](https://github.com/fluxerapp/fluxer/blob/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd/fluxer_api/src/api/database/PostgresKvQueryExecutor.ts), [fluxer_svc/src/postgres.rs](https://github.com/fluxerapp/fluxer/blob/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd/fluxer_svc/src/postgres.rs)), so they can only run against a writable primary. Making the Postgres primary the single source of truth for "which site serves" means **at most one site can ever accept writes**. A replica is read-only, so an app tier that started there by mistake couldn't commit anything.

## Tiers

[lib/tiers.sh](../lib/tiers.sh) lists every service once:

| Tier | Services | Where it runs | Who starts it |
|---|---|---|---|
| **Cold** | edge, api, worker, push, users(-shard), messages(-shard), admin, app-proxy, livekit | the primary only | the controller, `restart: "no"` so a rebooted spare starts none of them |
| **Warm** | gateway, media-proxy, static-proxy, snowflakes(-shard), gifs(-shard), unfurl(-shard) | both | Docker; the controller checks they're up, and restarts the gateway at role changes (below) |
| **Data** | etcd, postgres (Patroni), valkey, nats, meilisearch, seaweedfs, valkey-role-link, filer-sync, s3-mirror | both, always | Docker; never the controller |

The **edge** is cold. On the spare nothing serves the Fluxer domain: either nothing listens (bundled TLS) or your proxy has no upstream and closes the connection ([reverse-proxies.md](reverse-proxies.md)). That's the traffic-side fence.

## Who starts what: the controller

[lib/controller.sh](../lib/controller.sh) runs on both sites and polls every 2 s:

- **Patroni says this site is primary:**
  - repoint DNS here, in the background;
  - check the snowflake clock gate;
  - start the cold tier.
- **Anything else** (replica, Patroni down, can't tell), for 3 polls in a row: stop the cold tier, edge first. This direction is fail-closed. Stopping uses `docker stop` by label, so it works even when the compose files don't parse.
- **Never:** promote or demote Postgres, touch the data tier, or apply a configuration change. Every `docker compose up` uses `--no-deps`, and the warm check also `--no-recreate`. (Before that rule, an `.env` edit made both lab sites recreate etcd and Postgres within seconds of each other: [lab-results.md](lab-results.md) F27.) Changes go out with `fluxer-ha rollout`.

## Fencing: why two sites can't both serve

| Layer | Mechanism |
|---|---|
| Database | Patroni holds a **leader lease** in etcd (ttl 20 s). Only the holder runs Postgres read-write. Losing the lease demotes it. |
| Lease loss without demotion | The **watchdog**: if Patroni can't renew in time (frozen, overloaded), the kernel resets the host before another node can take the lease (`watchdog: mode: required`, [patroni.yml](../patroni/patroni.yml)). |
| Quorum | etcd needs 2 of 3 votes. An isolated site has 1 and can never take the lease. |
| App tier | Started only where Patroni says primary; stopped within about 6 s otherwise. |
| Traffic | DNS points at the primary. On the spare the edge is down, so nothing serves the domain. |
| Writes from a demoted site | Impossible: a replica is read-only. |

In the lab an isolated primary acknowledged **0** writes after the isolation, and no drill ever had both sites serving ([lab-results.md](lab-results.md)).

## Data

| State | How it's copied | Loss at an unplanned failover |
|---|---|---|
| **Postgres** | Streaming replication, **synchronous**: a commit returns only once the spare has it. Patroni promotes only the sync standby. With the spare gone, Patroni drops to async (`synchronous_mode_strict: false`) so the primary keeps working. A missing spare's slot, and with it the WAL it needs, is kept for 24 h (capped at 10 GB); a spare that comes back later than that is re-cloned automatically ([operations.md](operations.md#when-the-spare-is-down)). | **None** while the spare is in sync. If the spare was down or behind, there's no automatic failover (see below). |
| **Valkey** (sessions, caches, rate limits) | Valkey replication, pointed at the current primary by `valkey-role-link` every 2 s | Whatever replication hadn't sent yet: it grows with the round trip between the sites and the write rate. Lab (0.5 ms between sites, 100 writes/s, hard power-off): **0 of 1,396** lost. Over a WAN, expect up to about a second. That's acceptable for sessions, caches and rate limits, which is what Valkey holds. |
| **Media** (SeaweedFS buckets) | `weed filer.sync`, primary to spare, seconds behind. `s3-mirror` pushes anything left only on the old primary back up after a failover, and reconciles hourly. | Objects uploaded in the last seconds may be missing until the old primary returns; then they're pushed back. |
| **NATS JetStream** (the job queue) | Not replicated. | Jobs queued on the old primary and not yet run wait for it to come back. Failback waits for in-flight jobs first ([JobLedgerRepository.ts](https://github.com/fluxerapp/fluxer/blob/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd/fluxer_api/src/api/jobs/JobLedgerRepository.ts)). |
| **Meilisearch** | Not replicated. Its data rebuilds when the API starts ([install.sh:196](https://github.com/fluxerapp/fluxer/blob/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd/fluxer_docs/src/installer/install.sh#L196)). | Search is incomplete until the rebuild finishes. |

## Snowflake IDs

Both sites run the snowflake service, and a site could start minting IDs within a millisecond of the other's last one. To keep IDs unique, the sites use **different worker IDs**:
- **Site 1** keeps worker 0, the stock value.
- **Site 2** runs its shard as shard 1 of 2. The shard ID is passed as the worker ID ([main.rs:37](https://github.com/fluxerapp/fluxer/blob/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd/fluxer_snowflakes/src/main.rs#L37), [shard_impl.rs:15](https://github.com/fluxerapp/fluxer/blob/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd/fluxer_snowflakes/src/shard_impl.rs#L15)). Site 2's API and worker ask that shard directly (`FLUXER_SNOWFLAKE_SERVICE_SUBJECT`, [ServiceRegistry.ts:42](https://github.com/fluxerapp/fluxer/blob/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd/fluxer_api/src/api/middleware/ServiceRegistry.ts#L42)).

The controller also holds the app tier at promotion until both of these hold:
- chrony's offset is under 100 ms;
- the clock is past the newest stored message ID's timestamp. The epoch is [generator.rs:5](https://github.com/fluxerapp/fluxer/blob/c0f825ae2aa3e1508a5b58df8a239b16e7d7a4cd/fluxer_snowflakes/src/generator.rs#L5).

This guards against a site whose clock is behind minting IDs that sort before existing ones.

## Failover, step by step (primary powered off)

1. Patroni on the spare sees the leader lease expire (about 20 s). With etcd's vote from the witness, it promotes itself. It's eligible because it was the synchronous standby.
2. Its controller sees `/primary`, starts the DNS update and checks the clock gate, then starts the cold tier.
3. DNS moves within a second. Clients follow as their resolvers' TTL (60 s) expires; gateway sessions reconnect.

Lab result: the edge back after about **25–37 s**, writes through public DNS after about 25–41 s, with **0 acknowledged writes lost**.

## Failback

[lib/failback.sh](../lib/failback.sh) runs every minute and acts only on the preferred site (`FLUXER_HA_PREFERRED_SITE`), and only while it's the spare.

**It switches back** with a planned, zero-loss switchover once the site has been continuously healthy for `FLUXER_HA_FAILBACK_STABLE_SECONDS` (1 h). "Healthy" means:
- the sync standby;
- every health check passing, configuration included;
- no reboot, Postgres restart or timeline change in that time.

**Before switching** it also waits:
- for the optional hours window;
- for in-flight background jobs on the current primary.

**After switching** it verifies within 10 min that the site serves `/api/_health` and that DNS points there. If not:
- it **switches back** and holds off for 6 h, doubling up to 7 days;
- if the preferred site loses the primary role within a day of a failback, the next window doubles (anti-flap).

**The gateway restarts at role changes** (lab F43, F47). It fetches its rollout config from the API once at start, and only the primary runs the API, so a spare's gateway never gets it (F47). Its guild state is updated only by the API's messages over that site's NATS. A guild process with sessions stops 30 s after the last one leaves, which a demotion causes, so it doesn't go stale (tested: F43). One loaded only by API calls isn't stopped that way. The controller restarts it when the site is demoted, which costs nothing because the spare has no clients. After a promotion, once the API is healthy, it restarts it again if the config fetch failed, about 17 s into a failover, while DNS is still moving clients over.

An empty `fluxer-ha/state/failback.latched` (`fluxer-ha hold`) stops failback until removed.

## When automatic failover won't happen (by design)

| Situation | Why not | What to do |
|---|---|---|
| The spare was down or not in sync when the primary died | Promoting it would lose the commits it missed | [operations.md](operations.md#when-the-spare-is-down) |
| The primary and the witness are both gone | The spare has 1 of 3 votes | Manual: [operations.md](operations.md#primary-and-witness-both-lost) |
| Patroni is paused (`patronictl pause`) | You asked it not to act | `patronictl resume` |

## Network and ports

Everything between hosts goes over **WireGuard**. Published only on each site's WireGuard address: Postgres 5432, Patroni 8008, etcd 2379/2380, Valkey 6379, S3 8333, filer 8888/18888.

[lib/firewall.sh](../lib/firewall.sh) puts rules in Docker's `DOCKER-USER` chain:
- the peer site gets all of them;
- the witness gets only etcd;
- anything else on WireGuard gets nothing;
- **nothing reaches the WireGuard address except through WireGuard.** Linux accepts a packet for a local address on any interface, so without this rule a LAN neighbour could route to these ports directly ([security.md](security.md) S14).

The witness runs the same firewall: only the two sites, and only etcd.

Ordinary host rules (ufw, INPUT) never see Docker-published ports, because Docker DNATs them through FORWARD ([lab-results.md](lab-results.md) F12).

Public: 80/443 (the edge or your proxy) and LiveKit's ports, on the primary only.
