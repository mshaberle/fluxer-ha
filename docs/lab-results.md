# Lab results

Everything here was measured on a disposable lab, not in production: nine runs between 2026-10-15 and 2026-10-17, most of them installed from scratch by [install.md](install.md).

**In short:**
- **No acknowledged write was lost** in any drill of any run: messages, attachments, or the database writer's rows. Since the eighth run, every acknowledged attachment has also been downloaded again and compared byte for byte, and none differed.
- **No drill had both sites serving,** and an isolated primary acknowledged 0 writes. The one time both sites answered was `install.sh --update` run on the primary, which the docs forbid: for 4 s, with nothing writable on the old side ([Upstream's `install.sh`](#upstreams-installsh)).
- **Typical edge outages:** 1.5–6 s for a planned switchover or an automatic failback (9–14 s in the ninth run), 25–37 s for a hard power-off of the primary. A client going through public DNS can wait up to the 60 s TTL on top.

## The lab

| | |
|---|---|
| Hosts | Proxmox VE. Runs 1–4: site VMs with 6 vCPU, 12 GB and 60 GB. From run 5: a Ryzen 5 3600 host with 31 GB and one 500 GB consumer SSD shared by every VM, and sites with 4 vCPU and 10 GB. Each site has a virtual `i6300esb` watchdog; the witness has 1 vCPU and 2 GB. Debian 13, Docker 29.9.1, Compose 5.6.0. |
| Network | One bridge (0.5–0.9 ms between the VMs), with the WireGuard mesh on top. **No real WAN;** latency was added with netem where noted. |
| Fluxer | Upstream's stack files and `install.sh` at `c0f825ae2` (runs 1–8) and `51ef7393c` (run 9), with the day's `v1` images. |
| In front of the edge | Bundled TLS with `FLUXER_EDGE_GLOBAL_OPTIONS=local_certs` (runs 1–5), because a private test domain can't use public ACME. From run 6: the owner's own Caddy in Docker, with `install.sh --tls proxy`. |
| DNS | A real Cloudflare zone, DNS-only, TTL 60, pointing at private lab addresses |
| Measurement | `tests/probe.mjs` from the witness: a message every 2 s, an attachment every 10 s (two since run 8), a gateway session, an edge probe of both sites every 0.5 s, a browser-like keep-alive client (since run 6), plus a database writer committing about 16 rows/s. Since run 8 the probe is a real account in a real community, through a resolver that follows public DNS and trusts the lab CA. Afterwards `tests/analyze.mjs --verify` reads every message and attachment back. |

**Reading the numbers:**
- **Edge outage:** how long the serving site's edge didn't answer, from the edge probe. It doesn't include DNS.
- **User path, or "real client: writes back":** until a write through public DNS worked again, so it includes the 60 s TTL as 1.1.1.1 served it. Run 1 calls it write RTO.
- **Gateway back:** until a new gateway session worked.
- **Writes lost:** acknowledged writes missing afterwards, out of those acknowledged during the drill.

## Runs at a glance

| Run | Date | What was new | `migrate` window | `join` | Primary powered off: edge / user path, lost | Audit |
|---|---|---|---|---|---|---|
| 1 | 2026-10-15 | First lab, with every security control on | — | — | — / 37.4 s, 0 of 247 | — |
| 2 | 2026-10-15 | The package, from a stock upstream install; then moved to running as the installing user | 56 s | 2 min 45 s | 30.2 / 29.3 s, 0 of 182 | — |
| 3 | 2026-10-16 | From scratch as the installing user, with 3,000,000 seed rows | 69 s | 80 s | 25.6 / 25.3 s, 0 of 182 | — |
| 4 | 2026-10-16 | Hardened (S14–S18), first live security audit | 59 s | 70 s | 30.2 / 31.2 s, 0 of 182 | 148 checks, 0 failures |
| 5 | 2026-10-16 | The new, smaller lab host | 75 s | 2 min 50 s | 26.0 s / —, 0 of 170 | 149, 0 failures |
| 6 | 2026-10-16 | The owner's setup: own Caddy, `--tls proxy` | 74 s | 6 s after the clone started | 28.0 / 29.3 s, 0 of 181 | — |
| 7 | 2026-10-16 | Everything in `fluxer-ha/`; the `exec` DNS hook, hooks, latency, other proxies, pinning | 85 s | 8 s after the clone | 29.4 / 29.3 s, 0 of 175 | — |
| 8 | 2026-10-17 | Real accounts and attachments, every `install.sh` flag | 72 s | — | — / 35.9 s, 0 of 52 | 268 checks, 1 real finding (H2) |
| 9 | 2026-10-17 | Upstream `51ef7393c`, the saved damaged files, upgrading fluxer-ha itself | 92 s | 2 min 47 s | 36.3 / 40.6 s, 0 of 53 | 268, 0 failures |

From run 3, every `migrate` restored all 3,000,000 seed rows.

## Drills with real accounts (runs 8 and 9)

`probe.mjs` ran as a real account (Bob) in a real community: a message every 2 s and two attachments every 10 s. Each drill was then checked byte for byte, alongside the database writer, the edge, DNS and the keep-alive probes. Two values are run 8 / run 9; edge outages were measured in run 9.

| Drill | Edge outage | Real client: writes back | Gateway back | Messages lost | Attachments compared (none differed) |
|---|---|---|---|---|---|
| Planned switchover | 9.1 s | 21.1 / 27.5 s | 45.4 / 29.8 s | 0 of 42 / 0 of 46 | 18 / 18 |
| Automatic failback (10-min window) | 12.1 s | 19.7 / 33.3 s | 47.5 / 36.1 s | 0 of 331 / 0 of 301 | 134 / 121 (F55) |
| Kill `api` (no failover) | 7.6 s | 12.8 / 14.2 s | none | 0 / 0 of 24 | 10 / 10 |
| Witness etcd stopped 120 s | none | none | none | 0 of 77 / 0 of 76 | 32 / 32 |
| Link between the sites cut 120 s | none | 19.2 / 16.3 s (no failover) | none | 0 of 77 / 0 of 79 | 34 / 34 |
| Spare's Postgres stopped 120 s | none | none | none | 0 / 0 of 87 | 36 / 36 |
| +3 ms between the sites, 120 s | none | none | none | 0 / 0 of 73 | 30 / 30 |
| Media mirror paused 120 s | none | none | none | 0 / 0 of 91 | 38 / 38 |
| **Patroni frozen** (watchdog reset at about 26 / 24 s) | 25.7 s | 39.1 / 40.2 s | 46.6 / 45.2 s | 0 / 0 of 27 | 12 / 12 |
| **Primary isolated** (watchdog reset at about 18 s) | 24.2 s | 37.0 / 39.7 s | 39.8 / 39.7 s | 0 of 51 / 0 of 50 | 22 / 22 |
| Spare shut down gracefully | none | none | none | 0 of 33 / 0 of 33 | 14 / 14 |
| **Primary powered off** | 36.3 s | 35.9 / 40.6 s | 37.0 / 52.6 s | 0 of 52 / 0 of 53 | 22 / 22 |
| Failback after it (anti-flap: 20 min) | 13.6 s | Run 8: blocked by F49 for 33 min, none once fixed / 36.5 s | none / 36.5 s | 0 of 923 / 0 of 684 | 374 / 278 |

- **The database writer** lost **0** rows in every drill (17,657 in run 9's last). A firewall chain flushed by hand was back after 11 s (run 8) and 5 s (run 9).
- **Real conversation (run 9):** Alice and Bob each opened a gateway session and shared a PNG, a PDF, a text file and a 50 KB binary. Each file came back through Fluxer with the same SHA-256, and all of it was there after the power-off, after the failback and at the end.
- **The probe itself:** a new user's first message fails with `MUST_START_SESSION_BEFORE_SENDING` until they have a gateway session, so the probe waits for one. Its nonce was 33 characters at first, and the API takes 32; that was fixed, and the drill re-run clean.
- **In run 9:** the witness drill was re-run once F54 was fixed. Valkey came back cleanly after both watchdog resets and the power-off (F49 didn't recur). One probe write timed out during a lab disk stall ([run 9](#run-9-upstream-51ef7393c-and-the-saved-damaged-files-2026-10-17-evening)).

## Earlier drills (runs 1–7)

**Run 1** (the first lab's third pass of the drills, every security control on) measured RTO on the user's path. Server-side, a planned switchover took about 4 s and a power-off about 30 s.

| Drill | Write RTO | Gateway RTO | Acked DB writes lost |
|---|---|---|---|
| Kill `api` on the primary | 7.4 s | 0 s | 0 of 928 |
| Kill `gateway` | 0 s | 3.5 s | 0 of 956 |
| Witness down 2 min | 0 s | 0 s | 0 of 2,409 |
| Link between the sites cut 2 min (no failover) | 17.1 s | 0 s | 0 of 2,412 |
| Spare's Postgres stopped 2 min | 0 s | 0 s | 0 of 2,859 |
| +3 ms between the sites | 0 s | 0 s | 0 of 1,778 |
| Media sync paused 2 min | 0 s | 0 s | 0 of 3,276 |
| Planned switchover | 19.7 s | 27.0 s | 0 of 1,738 |
| Automatic failback (10-min test window) | 33.8 s | 27.2 s | 0 of 11,039 |
| Primary isolated, with a writer on it | 33.0 s | 38.4 s | 0 of 1,666; **the isolated primary acknowledged 0 writes** |
| Patroni frozen (watchdog reset) | 36.2 s | 44.0 s | 0 of 1,760 |
| Primary powered off | 37.4 s | 37.1 s | 0 of 247; the rebooted host started no app services |
| Clock out of sync at promotion (held on purpose) | 69.8 s | 71.8 s | 0 of 1,787 |
| DNS update failing, then fixed | 78.5 s | 88.8 s | 0 of 1,702 |

**Runs 3–7**, as documented in [testing.md](testing.md). Each value is the edge outage, with the user path in brackets where it was measured. Every drill lost **0** acknowledged writes.

| Drill | Run 3 | Run 4 | Run 5 | Run 6 | Run 7 |
|---|---|---|---|---|---|
| Kill `api` (needs `sudo`), no failover | 4.7 s (2.1 s) | 4.6 s (1.1 s) | 6.2 s | — | 9.1 s (13.2 s) |
| Witness down 2 min | none | none | none | — | none (1.0 s) |
| Link between the sites cut 2 min | none; 11 s commit stall | none; 14 s stall | none; 14 s stall | — | none |
| Spare's Postgres stopped 2 min | none | none | none | — | none |
| Firewall chain flushed by hand | re-applied in 28 s | 28 s | 31 s | — | 23 s |
| Rollout on the spare, switchover, rollout | none / 2.5 s / none | none / 2.5 s (3.1 s) / none | 4.6 s at the switchover | — | — |
| Planned switchover | 1.5 s (7.3 s) | 2.5 s (4.2 s) | 2.6 s | 3.0 s (5.1 s) | 3.0 s (12.6 s) |
| Automatic failback (10 min) | 2.0 s (3.2 s) | 3.0 s (4.1 s) | 3.1 s | 6.1 s (5.1 s) | 4.5 s (5.2 s) |
| Primary powered off | 25.6 s (25.3 s) | 30.2 s (31.2 s) | 26.0 s | 28.0 s (29.3 s) | 29.4 s (29.3 s) |
| Failback after it (anti-flap: 20 min) | 4.1 s (7.2 s) | 2.0 s (5.2 s) | 4.6 s | 4.5 s (8.8 s) | not measured |
| Spare shut down gracefully | none; longest write gap 1 s | none | none | — | — |
| An `on-primary` hook that hangs (5 s limit) | — | — | — | — | 3.0 s (9.1 s) |

Every role change and failback reached the alert URL. After a power-off, the rebooted host started no app services, and it was sync standby again 30 s after power-on (run 3).

## Findings that changed the design

Each of these was found in the lab, or by reading while testing, and is fixed in this repository.

| # | Finding | Fix |
|---|---|---|
| F2 | Upstream's Postgres image sets `STOPSIGNAL SIGINT`; Patroni only hands over cleanly on SIGTERM | `STOPSIGNAL SIGTERM` in the Patroni image |
| F3 | The clock gate queried a table that doesn't exist on a fresh database, so the app tier never started | Check the table exists first |
| F4 | There's no stack-wide release tag: `v1` pointed at images from six different commits | Optional digest pinning (`fluxer-ha pin`) |
| F6 | A Caddy reload keeps serving the cached certificate | Restart (rate-limited) after a certificate copy |
| F11 | A primary that is also the etcd leader delays its own failover by up to a lease | Keep etcd leadership on the witness |
| F12 | Host firewall rules don't see Docker-published ports | Rules in `DOCKER-USER`; the drills cut WireGuard's UDP |
| F15 | A DNS retry kept stale settings after you fixed them | Settings re-read on every attempt |
| F16 | Keep-alive clients stayed pinned to the old site for minutes | Close the connection on 502 (bundled TLS: nothing listens) |
| F20 | A udev subsystem trigger misses `/dev/watchdog` | Trigger the device paths |
| F22 | `docker compose exec` swallowed the drills' typed confirmation | `</dev/null` on every exec |
| F27 | **Editing `.env` made both sites recreate etcd and Postgres at once** (quorum lost, three role changes) | The controller never applies changes; `fluxer-ha rollout`, one site at a time |
| F28 | Two concurrent firewall applies could briefly drop the sites' traffic | A lock and an atomic chain swap |
| F29 | dash's `echo` corrupted JSON, and a pin file with 0 services passed for success | `printf`; refuse empty results |
| F30 | `valkey-cli ping` exits 0 on `NOAUTH` | A healthcheck that requires `PONG` |
| F33 | With a lock file in place, `pull` fetched the old digests | `fluxer-ha pin --pull` |
| F34 | A new etcd cluster with a member that has never started reports cluster version `3.0.0`; Patroni then uses an API path etcd 3.5 doesn't serve and waits forever | `fluxer-ha etcd-up` on site 2 before `migrate`; `migrate` checks all three members and waits for a real cluster version |
| F35 | A spare away longer than Patroni's slot retention (30 min by default) never catches up, and Patroni doesn't re-clone it | `member_slots_ttl: 24h` with a 10 GB cap; `ha-health.sh` re-clones a stranded spare automatically |
| F36 | `docker logs --since` returned nothing on Docker 29.9.1 | Use `--tail` |
| F37 | A graceful shutdown of the spare stalled the primary's commits for 11 s, because WireGuard stopped before Docker | A drop-in that orders Docker after WireGuard: 1–3 s |
| F38 | Cloning a replica began with a **spread** checkpoint on the primary: `join` took 273 s for a 227 MB database, most of it waiting | `basebackup: checkpoint: fast` in `patroni.yml`: sync standby 8 s after the clone started |
| F39 | After `migrate`, site 1's warm tier was the old single-site containers, restarted with their pre-HA settings (a `FLUXER_KV_URL` without Valkey's password), until the first `rollout` | `migrate` recreates the warm tier inside the window |
| F40 | With the owner's own Caddy, a switchover 68 s before the first certificate copy left the new primary serving a certificate the other site didn't trust, and the spare's health check had reported the pair safe | The copy runs 2 min after boot, then hourly. The spare's health check fails while the certificate it would serve isn't valid for the domain, trusted, and short of its renewal point |
| F41 | Moving an existing install into `fluxer-ha/` rewrote `COMPOSE_FILE` in `.env.shared`, but `init` keeps it in `.env.site`: after the move, `docker compose` couldn't find `ha.compose.yml` (the containers kept running) | The move rewrites both files; the running pair was repaired and rolled out with 0 writes lost |
| F42 | Upstream's `install.sh --rollback` on an HA site re-tags its recorded images in order and stops with exit 3 at the first digest-pinned HA image (Docker refuses to tag a digest reference). The ones before it stay moved, and its files aren't restored. Its record holds no app images under HA anyway | `fluxer-ha rollback`, which reads install.sh's records and fluxer-ha's own, then the usual rollout (operations.md) |
| F43 | Read from the gateway's code: guild state changes only through dispatches, and each site has its own NATS, so a demoted site's gateway might keep stale state. **The lab disproved it** (run 8, real accounts, the gateway restarts off): a member denied `SEND_MESSAGES` on site 2 was still refused back on site 1. A guild process stops 30 s after its last session leaves (`AUTO_STOP_EMPTY_GRACE_MS`), and a demotion ends every session. Still open: a guild loaded only by API calls, never by a session, isn't stopped that way | The controller still restarts the gateway on demotion, which covers that case and costs nothing (the spare has no clients) |
| F44 | nginx in Docker with `proxy_pass http://fluxer-edge-1:8080` exits on the spare (`host not found in upstream`): the spare has no edge container | Docker's resolver and a variable upstream (reverse-proxies.md) |
| F45 | Found by reading: the controller ran your hooks with no time limit, and its loop waits for them, so a hanging `on-primary` hook would also keep it from stopping the app tier at the next demotion | 60 s limit (`FLUXER_HA_HOOK_TIMEOUT_SECONDS`), then an alert |
| F46 | Found by reading: `leave` with `--proxy-network` kept `fluxer-ha/ha.proxy-network.yml` in the single-site `COMPOSE_FILE`, which deleting `fluxer-ha/` (as documented) would break. And `init` dropped any overlay of yours from `COMPOSE_FILE` without a word | `leave` writes `~/fluxer/proxy-network.compose.yml` with the network named in it (upstream's own pattern for a proxy on a Docker network) and leaves no `FLUXER_HA_*` key. `init` keeps your overlays, and `bundle` takes them to site 2. Lab: `fluxer-ha/` deleted, then `install.sh --update`: HTTPS 200 |
| F47 | The gateway fetches its rollout config from the API once, 2 s after it starts, and never again unless an admin changes it. If the API isn't up yet, it runs on the defaults; on the spare there's no API, so it never has it. After a reboot it's a race (the lab's primary lost it too). An upstream bug; it matters only if you've changed those settings | After a promotion, once the API is healthy, the controller restarts the gateway if its fetch failed since it started. Lab: 17 s after the promotion, back in 3 s, then loaded. On a running primary it logs a warning instead |
| F48 | With Docker's containerd image store (Docker 29's default), moving a tag deletes the old image's local entry at once: no dangling image, so `docker image inspect <old ID>` fails, and the first `fluxer-ha rollback` test found every old image "gone". There, though, an image's ID is its registry digest | `rollback` pulls `<repository>@<old ID>` back; `upgrade-fetch` also records images before the pull. Lab: 12 images back from ghcr.io in 13 s |
| F49 | After a hard power-off of the primary (run 8), the old primary came back with a damaged Valkey append-only file (`Bad file format reading the append only file`), and Valkey restarted 43 times in 33 min. The spare's health check failed (`valkey link down`), which also blocked failback, and that site couldn't have taken over | `ha-health` repairs it on both sites (`lib/valkey-repair.sh`), keeping the damaged files in `fluxer-ha/errors/valkey-<time>/`. On the spare it starts empty and re-syncs. On the primary, `valkey-check-aof --fix` cuts the damaged `.aof` file at the record; if that isn't enough, or the base RDB is damaged, it starts empty (the owner's choice: service before downtime). Lab: the saved files, [run 9](#the-saved-damaged-files) |
| F50 | `s3-mirror`'s `rclone sync` hung for over 13 min, and `rclone --timeout 30s --contimeout 10s` didn't end it (tested: 420 s, with those flags and with rclone's defaults). Nothing restarted it, and the spare's health check failed (`s3-mirror unhealthy`) | An rclone run is killed after `FLUXER_HA_S3_MIRROR_STALL_SECONDS` (default 300) **without progress**, judged by rclone's own counters; a run that's moving has no limit. The next run carries on where it stopped. Lab, with the link to the primary's S3 dropped: killed at the 60 s set for the test, healthy again once the link came back |
| F51 | `rollout` waits up to 300 s for every data-tier service to be healthy, `s3-mirror` included. But a freshly created mirror reports healthy only after a full reconcile, so with a lot of media the rollout would time out | (The owner's choice: a full copy, no time limit.) s3-mirror is the last step of `rollout`, which asks it for a full sync and waits for it with no time limit, printing progress. It stops only after `FLUXER_HA_S3_MIRROR_STALL_SECONDS` (300) without progress, with everything else rolled out; running it again resumes. Lab: [run 9](#the-saved-damaged-files) |
| F52 | An upload written on the primary about 8 s before its watchdog reset it (run 8's isolation drill) kept its SeaweedFS metadata, but its data chunk now answers HTTP 500. Reading the object through S3 **hangs** rather than failing, so every reconcile of that bucket stalled, and the spare stayed unhealthy. It was never acknowledged to the client: all 22 attachments acknowledged in that drill read back byte for byte | s3-mirror finds an object that makes no progress for `FLUXER_HA_S3_MIRROR_OBJECT_STALL_SECONDS` (60), skips it and mirrors the rest; each reconcile tries it again. Its record and SeaweedFS metadata go to `fluxer-ha/errors/s3-mirror/`, and the spare stays healthy with a warning and an alert (the owner's choice: failover stays available). Lab: [run 9](#the-saved-damaged-files) |
| F53 | After a switchover (run 9), the old primary's push-back to the new primary skipped an object it couldn't read (the replayed F52 upload, which existed only there). Twenty seconds later, its exact mirror from the new primary deleted it as "not on the primary". An upload stranded by a failover and only briefly unreadable would have been deleted instead of pushed later, and the damaged original was lost for examination. Skips from the push-back were also never retried, though the docs said each reconcile retries | The mirror from the primary excludes what the push-back skipped (rclone never deletes an excluded name), and each reconcile tries to push it again, never over an object the primary has (`--ignore-existing`). Lab: the same object through a switchover, the push-back, two reconciles and the switch back: kept on site 1 throughout |
| F54 | `install` copied fluxer-ha to `/usr/local/share/fluxer-ha` under the CLI's umask 027 (the H2 fix), so its folders were `root:root 750`. The installing user couldn't read them: the witness drill (`/usr/local/share/fluxer-ha/tests/gd-witness-outage.sh`) silently didn't run, and `fluxer-ha install site` from the `PATH` (what operations.md said to run after a `git pull`) copied nothing, so an update of fluxer-ha itself never arrived | `install` replaces those folders (a file a new version drops doesn't linger) and makes them readable by everyone, writable by root only: they hold only this repository. operations.md now says to run the **checkout's** `~/fluxer-ha/fluxer-ha install`, since the one on the `PATH` is the old version. Lab: the self-update again, and the witness drill re-run for real |
| F55 | Right after the automatic failback (run 9), `analyze.mjs` reported 1 of 121 acknowledged attachments unavailable. A re-run minutes later found all of them, byte for byte: it fetched each attachment once, while its history check already retried for a minute (DNS can still hand out the old site) | Test harness: the same retry for attachments, on no answer or a 5xx only, and each unavailable one is named |

## The spare going offline

The primary kept serving in every case, with no failover and no acknowledged write lost:

| Check | Longest write stall | Spare back |
|---|---|---|
| Graceful shutdown of the spare's host | 11 s; **1–3 s** with the shutdown-order drop-in (F37) | sync standby 20–30 s after boot |
| Spare cut off from every peer, still running | 14 s | 10 s after reconnecting. It stayed a replica and started nothing. |
| Spare powered off 45 min, 640 MB of WAL written meanwhile (30-min slot retention) | 11 s | **Never**, until a re-clone (F35). The automatic re-clone made it sync standby in 12 s (small lab database). |
| The same with the 24 h slot retention | — | Caught up by streaming, sync standby 34 s after power-on |
| Stranded past the WAL cap (cap lowered to 64 MB for the test) | — | The slot went `lost`; on power-on `ha-health.sh` re-cloned the spare by itself: sync standby **76 s after power-on** |
| Slot dropped by hand while it was off | — | Patroni recreated it at the spare's last position within 12 s; caught up by streaming 29 s after power-on |

## Latency between the sites

netem on WireGuard, in run 7 (the lab's own round trip is 0.5–0.9 ms):

| Added | Round trip | One commit | 2 minutes at it |
|---|---|---|---|
| 0 | 0.9 ms | 3.9 ms | stable |
| 10 ms | 10.3 ms | 18.0 ms | stable: no leader change, 0/12 health failures |
| 30 ms | 30.2 ms | 34.5 ms | stable |
| 60 ms | 60.3 ms | 69.1 ms | stable |
| 100 ms | 100.3 ms | 108.2 ms | stable |

With 60 ms on the spare's side (so the spare and the witness elected across it), a power-off of the primary: edge outage 27.2 s, user path 25.3 s, 0 of 67 lost.

## Your own reverse proxy

From run 6, both sites ran stock `caddy:2.11-alpine` in Docker as its own Compose project (`caddy_default`). It serves the Fluxer domain through a snippet, `(fluxer_edge)`, which forwards to the bundled edge (`fluxer-edge-1:8080`) and has `handle_errors 502 503 504 { abort }`, and it also serves a second site. fluxer-ha ran with `--proxy-network caddy_default` and certificate mode `caddy`.

- **`gd-proxy-fence.sh`** passed on both sites in runs 6 and 7: before the drills, with the roles swapped, after the power-off and at the end. On the spare, Caddy closed HTTP/1.1 and HTTP/2 connections instead of answering 502, and a kept-alive connection had to reconnect. On both sites the certificate was trusted and short of its renewal point, and the other site answered.
- **Negative control,** in runs 6–9: with `abort` removed from the spare's Caddyfile (edited in place, see [reverse-proxies.md](reverse-proxies.md)), the fence check **failed** all three connection checks and named the fix; restored, it passed. (Run 7's first attempt used `sed -i` and so tested nothing, the trap reverse-proxies.md describes.)
- **The keep-alive client (run 6)** got 0 × 502 in the switchover, both failbacks and the power-off, and was on the new site 3.5–8.3 s after its connection was closed (28.9 s at the power-off). The other site Caddy serves had 0 errors, except on the powered-off host itself. (In run 7, five 502s came from the kill-api drill: with `api` gone, the edge itself answers 502, which Caddy passes on. `abort` acts only when Caddy can't reach the edge.)
- **F40, the certificate on the spare (run 6):** with the lab CA's trust removed on the spare, `ha-health` failed ("the certificate on this spare … isn't trusted here"); with trust restored, it passed. A Caddy restart after a certificate copy wasn't exercised then, because the certificate hadn't changed; the one-restart-an-hour limit was tested in an earlier lab (S7).
- **Tested outside the pair (run 7):**
  - **nginx 1.29.8** in Docker on both sites, through a failback and the power-off (F44).
  - **Traefik 3.5.6** with a dead backend: 502 on a reused connection, with or without the errors middleware.
  - **Rootless Docker 29.9.1** on a separate VM: the firewall, `pg_hba` and the watchdog don't work with it ([security.md](security.md#what-runs-as-root)).

## Upgrades, pinning and rollback

- **Run 2, a pinned upgrade** (`pin --pull`, `rollout`, `switchover`, `rollout`): one switchover, edge outage 3.1 s, no dual serving.
- **Run 4, a rebuilt Patroni image** through rollout, switchover, rollout: 0 lost. Afterwards, only Postgres was flagged on the new spare, which confirms F39's fix.
- **Run 7, pinning on the `fluxer-ha/` layout:** on, drift, a pinned release (a new `api` digest under `v1`), its rollback and off, each through the full rollout with writes running. **0** lost in all seven rollouts, with edge outages of 3.0–6.1 s at each switchover. Every container ran the digests the lock named, on both sites. The drift message used to blame `.env.shared` alone; it now names both files.
- **Run 9, pinning** on with the day's images, a release under `v1` (a new `api` image built on one site and loaded on the other), `fluxer-ha rollback`, then off: each a rollout, a switchover and a rollout. **0** of 7,176, 6,166, 5,536 and 8,163 rows lost, with both sites on the same digests at each step.
- **Run 9, upgrading fluxer-ha itself under load:** F54 first. Once it was fixed, the documented steps recreated both `s3-mirror` containers with the new script: the checkout's `install site` on both sites, `install witness`, the rollout on the spare, a switchover, then the rollout on the other site. Until then, the spare's health check named `s3-mirror(script)`. Writes were out 23 s at the switchover, with 0 lost and 48 attachments byte-identical.
- **Other checks:** `upgrade-fetch` reported unchanged files and refused a release that bumps Postgres's major version. The "configuration not applied" check flagged a container recreated with a different setting, and `rollout` fixed only that container, in 8 s. A simulated release and `fluxer-ha rollback` are in operations.md ("Image versions and pinning").

## Upstream's `install.sh`

- **Run 7, on the spare:** `--update` accepted the `fluxer-ha/` overlay paths, left every file under `fluxer-ha/` byte-identical and lost 0 writes. It writes its records to `~/fluxer/backups/`, and the guard caught a secret it wrote. `--rollback` refused (F42).
- **Run 8, every flag on the spare,** with load (the table is in operations.md). `--update` on the primary failed over with 0 lost, as the docs warn.
- **Run 9, every flag again with `51ef7393c`:** the uploads copy now starts again only what was running before it. On the spare that's the data and warm tiers, as before. On the primary (which the docs forbid), the failover happens as before. But the old primary's `edge` and `api` started again 21 s after the demotion, and both sites answered for 4 s until the controller stopped them. Nothing could be written there (by then a read-only replica), 0 were lost, and it exits 0 instead of the old 600 s wait and exit 6.

## The saved damaged files

Run 8 left two damaged files, which run 9 replayed on the new pair: Valkey's append-only directory from F49, and site 1's SeaweedFS volume holding the F52 upload.
- **F49, Valkey:** the damaged files put on the spare were repaired in 11 s (it started empty and re-synced from the primary). On the primary, with the probe running, the repair took 17 s: `valkey-check-aof --fix` cut 1,237 bytes at the damaged record, writes were back in 28 s, and 0 were lost. Both alerts came, and both copies are in `fluxer-ha/errors/valkey-<time>/`. (In run 8, testing the primary path replaced site 1's lab Valkey data with the damaged copy; the repair then recovered it with `valkey-check-aof --fix`.)
- **F52, SeaweedFS:** the saved volume was mounted on the new primary under a free volume ID, with the object's filer entry. Its needle's data runs past the end of the volume file, cut off by the reset, so it fails the same way anywhere. `filer-sync` retried it forever (16 log lines a minute), while new uploads still replicated. The spare's rollout skipped it after 434 s, kept the record and stayed healthy.
- **F51, the rollout's media sync:**
  - **Normal:** 108 s (run 8: 114 s and 103 s).
  - **With the spare's mirror cut off from the primary's S3:** it stopped after 668 s with exit 1 and "made no progress … can this site reach the other site's S3?". In run 8 it stopped after 10.5 min on the first bucket.
  - **Run again:** it recreated nothing and finished in 102 s.
- **F53, found here:** the drills' switchovers made the old primary's mirror delete the F52 object. Once fixed, the same object survived the push-back, two reconciles and the switch back.

## Security audits

The live audit ran from a LAN neighbour (the Proxmox host), the witness, the peer without credentials, the peer's SSH key against the gate, and each host.

| Run | Checks | Result |
|---|---|---|
| 4 | 148 | Before S14, the LAN neighbour reached every HA port and listed the filer's buckets. After it: **0 failures.** Six checks first reported FAIL because of bugs in the test harness, such as reading a root-only file through a user redirect; each passed once re-tested properly |
| 5 | 149 | 0 failures |
| 8 | 268 | 260 passed. 7 of the 8 failures were the audit scripts themselves (a role assumption, boolean output from Postgres 16, a comment line, the witness's path); each passed once re-run correctly. Real: **H2**, state files group-writable when the CLI or `ha-health.sh` ran from a login shell (Debian's umask 002); both now set the units' `UMask=0027` |
| 9 | 268 | All passed. G5 failed at first only because it ran from site 2 while site 2 was primary; run from the spare, as the script says, it passed (the wrapper now picks the spare) |

systemd exposure was 3.3 and 3.6 in runs 8 and 9. Trivy 0.76, fixable HIGH/CRITICAL findings:

| Image | Run 8 | Run 9 |
|---|---|---|
| fluxer-ha's Patroni image, rclone | 0 | 0 |
| etcd (its Go dependencies) | 12 | 12 |
| Upstream's images as they ship: caddy, seaweedfs, gateway, media-proxy, static | 4, 5, 6, 6, 4 | 4, 5, 6, **11**, 4 |

## Run notes

What each run found beyond the sections above.

### Run 2: the package from a stock upstream install (2026-10-15)

**The setup:** upstream's `install.sh` at `c0f825ae2`, run as a normal user with the defaults (bundled TLS, `~/fluxer`). Its only change was copying the stack files from a local checkout of the same commit instead of downloading them. Then the `fluxer-ha` steps from [install.md](install.md): `doctor`, `init`, `bundle`, `install`, `witness-up`, `ssh-link`, `etcd-up`, `migrate`, `join`.

| Step | Result |
|---|---|
| `migrate` | Window about **56 s** (near-empty database), rows checked before and after. The first two attempts failed (F34, the package bugs below) and **rolled back on their own** to the running single-site instance |
| `join` | Site 2 sync standby **96 s** after the clone started (2 min 45 s in all, with image pulls) |
| `status`, `doctor`, the SSH link | Worked; the gate refused `id` |
| Firewall from the witness | Only etcd reachable (plus the lab's explicit hole for its test writer) |
| Hard power-off of the primary | Edge outage 30.2 s, user path 29.3 s, **0 of 182** lost; the rebooted host started no app services |
| Automatic failback, first attempt | It switched over on its own after the window (doubled to 20 min by the anti-flap rule after an earlier failback): edge outage 4.6 s, 0 of 1,338 lost. Its HTTPS check then failed, because the sites didn't trust the lab's private CA. After 10 min it **switched back on its own** and backed off for 6 h, as designed. (A lab setup fault; `fluxer-ha release` cleared the back-off.) |
| Automatic failback, after trusting the CA | **Verified**: "serving 20 s after the switchover". Edge outage 3.0 s, user path 1.0 s, **0 of 10,600** lost, no dual serving |
| Certificate copy (bundled edge) | The spare's edge volume received the primary's certificate |

**Moved to running as the installing user** (`debian`), by running `fluxer-ha install site` again as that account. Its root steps ran through `sudo`: the SSH key moved out of `/root/.ssh`, `~/fluxer/fluxer-ha` and its `state` were handed to the account, the units were re-rendered with `User=debian`, and the controller restarted with every container left as it was.

| Check | Result |
|---|---|
| `sudo fluxer-ha status` | Refused: "Running as root. Use an account in the docker group, or pass --allow-root." `--allow-root` on an install made for `debian` was refused too |
| Unit users | controller, health, failback and certs `User=debian`; only the two firewall units are root |
| Drift check and certificate copy through the gate's `sudo -u debian` | Worked both ways |
| Firewall chain flushed by hand | The root check timer re-applied it, with an alert, within 10 s |
| Hard power-off of the primary | Edge outage 30.2 s, user path 30.3 s, 0 of 182 lost; DNS moved by the non-root controller |
| Automatic failback | Verified "serving 30 s after the switchover"; edge outage 3.6 s, **0 of 19,797** lost |

**Bugs found in the package, all fixed:**
- `migrate`'s pre-flight tested the witness on a port a lone member doesn't serve.
- Shell variable clashes: `doctor` overwrote `migrate`'s table name, and a helper overwrote its timer.
- `init` packed site 2's bundle before you edit `.env.shared` (now `fluxer-ha bundle`).
- `build-env.sh` took `.env` away from the installer's user.
- The SSH gate needed a generated `.env` that site 2 doesn't have before `join`.
- A certificate arriving before `join` created the edge volume without Compose's labels.
- The HTTPS check used the DNS record's name instead of the certificate's (`FLUXER_DOMAIN`).
- The rollback left a half-made Patroni volume behind.

### Run 3: from scratch as the installing user (2026-10-16)

Three new VMs: a stock upstream `install.sh` as `debian`, then 3,000,000 seed rows (a 227 MB database). Every step of install.md ran as that account; only `install`, `ssh-link`, `migrate`, `join` and `etcd-up` asked `sudo` for their `[root]` steps. The heartbeat and alert URLs pointed at a small HTTP sink on the witness. The heartbeat pinged every 30 s from the spare, stopped while the witness was down and resumed afterwards. `doctor` passed on all three hosts, including a bare site 2. The gate allowed `env-hash` both ways and refused everything else.

The first attempt found four problems, all fixed before the VMs were rebuilt and the install run again:
- **F38:** `join` waited 273 s on a spread checkpoint. It now takes 8 s.
- **F39:** `migrate` left the warm tier on its pre-HA settings.
- **`doctor`:** it stopped on a bare site 2, and FAILed on the bundle's files before `join`.
- **The drills:** `gd-kill-service.sh` needs `sudo`, and now says so. `gd-switchover.sh` and `gd-failback.sh` checked HTTPS by the DNS record's name instead of the certificate's.

### Run 4: hardened (2026-10-16)

The same three VMs, reset and installed from scratch with the security fixes S14–S18 ([security.md](security.md)), all three hosts with the firewall on. The first attempt stopped safely: the new firewall's self-check didn't match how `iptables` prints `--ctorigdst`, so site 2's etcd never started and `migrate` refused before changing anything. The rewritten `cert-receive` installed the certificate.

### Run 7: everything in `fluxer-ha/` (2026-10-16, evening)

**The setup:** as run 6, with fluxer-ha's files in `~/fluxer/fluxer-ha/` and the state in `~/fluxer/fluxer-ha/state` instead of `/var/lib/fluxer-ha`. DNS went through the **`exec` provider**, with a lab hook that PATCHes the same Cloudflare record. Marker `on-primary`/`on-replica` hooks were installed.

- **Moving the running pair** from the old layout: `install site` on the spare, then on the primary, moved every file and the state, stopping the controller and timers only for the move. One bug (F41) left `COMPOSE_FILE` on the old paths. Once it was fixed: rollout, switchover, rollout with writes running, **0** lost, edge outage 6 s.
- **Moving from a root-owned old layout** (the old files and `/var/lib/fluxer-ha` handed to root first): `install site` took them over, moved everything, and rewrote `COMPOSE_FILE` and a DNS hook path. The rollout afterwards lost **0** of 1,335 writes. On that snapshot, the witness's etcd hadn't rejoined after the restore: its raft log no longer matched, because the three VMs' snapshots weren't taken at the same moment. That's a lab artefact; removing the member, adding it again and wiping its data (operations.md) brought it back in seconds.
- **From scratch:** the tree matches [install.md](install.md). Re-running `install site` over it changed no container and left `hooks/` alone.
- **The `exec` DNS hook** moved the record at every role change (a switchover, two failbacks, the power-off), from inside the controller's sandbox. A hook in a group-writable file or directory was refused, with a "not configured" alert.
- **Hooks** ran as uid 1000 from `~/fluxer` at every role change.
- **The second failback wasn't measured:** my own edit of the drill script while it ran broke it after the failback, so that row's probes stopped early. The keep-alive client was back on site 1 7 s after its connection closed, with 0 × 502.
- **`init` with an overlay of your own:** F46.

### Run 8: real accounts and attachments (2026-10-17)

**The setup:** a fresh install by install.md (proxy variant, the newest `v1` images: `api` built 2026-10-17), DNS through Cloudflare. The owner created the admin account and turned the CAPTCHA off. Then two test accounts (Alice, Bob), a community with channels, and an invite. Every path the docs name exists, or appears when its feature is first used.

**Bugs found in fluxer-ha:**
- `rollback --files` from an install.sh record stopped when `fluxer-ha/upgrade/` didn't exist yet.
- F49–F52.
- **Testing F51 found three more:**
  - On a dead link, the sync went on to the next bucket after a no-progress failure, about 10 min per bucket.
  - A skipped object whose listing got no answer was taken as deleted.
  - A sync request left by a stopped rollout was answered first.

All of these are fixed.

### Run 9: upstream `51ef7393c` and the saved damaged files (2026-10-17, evening)

**The setup:** the three VMs reset to `provisioned`, then a fresh install by install.md: the owner's Caddy in front of the edge, DNS through Cloudflare, the newest `v1` images (`api` built 2026-10-17 03:55 UTC). Upstream's stack files and installer came from `origin/main` at `51ef7393c`, 55 commits newer than `c0f825ae2`. The owner created the admin account and turned the CAPTCHA off. Then Alice and Bob joined "HA lab community", with #general, #probe and #attachments.

- **Install:** `join` took 2 min 47 s. Every path the docs name exists, or appears when its feature is first used. The spare's health check failed for about 50 s after `join`, until s3-mirror's first full copy finished. That's intended (failback never moves onto incomplete media), and install.md step 11 now says so.
- **Found:** F53, F54 and F55.
- **Different Fluxer directories:** after the run, site 2 (the spare) was moved to `~/docker/fluxer` while site 1 stayed in `~/fluxer`: `install site --dir ~/docker/fluxer`, the data and warm tiers started from there, then `rollout` (`ha-health OK`). A switchover made site 2 primary from the new path; site 1 then refused connections as the spare, and the real messages and attachments re-read through site 2 byte for byte.
- **Lab only, not fluxer-ha:**
  - **Shared disk:** a single 5.6–5.8 s `fdatasync` stall hit all three VMs at once (they share one consumer SSD). It came right after the witness pulled an image during site 1's checkpoint. Commits waited for it, and one probe write timed out.
  - **Replaying the object:** `weed shell`'s `fs.meta.load` reports "loaded" but writes nothing when it's the session's last command; another command after it fixes that.
