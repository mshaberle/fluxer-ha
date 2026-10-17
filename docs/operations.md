# Operations

Paths below assume your Fluxer directory is `~/fluxer`; if yours is elsewhere, use that instead. fluxer-ha finds it from `/etc/fluxer-ha/fluxer-ha.conf`. Every command and option is in [commands.md](commands.md).

## What runs where

| Unit (both sites) | Runs as | What |
|---|---|---|
| `fluxer-ha-controller.service` | you | Runs the app tier where Patroni is primary; repoints DNS |
| `fluxer-ha-health.timer` (30 s) | you | Checks everything, and on the spare pings your heartbeat while failover is possible |
| `fluxer-ha-failback.timer` (60 s) | you | Acts on the preferred site only |
| `fluxer-ha-certs.timer` (2 min after boot, then hourly) | you | Copies the certificate from the primary to the spare; the spare's health check fails while it has no valid, trusted copy (F40) |
| `fluxer-ha-firewall.service`, `fluxer-ha-firewall-check.timer` (30 s), **also on the witness** | root | The `DOCKER-USER` rules: applied at boot, checked and re-applied every 30 s |

"You" is the account that installed Fluxer, or root if `fluxer-ha` was installed with `--allow-root`.

Logs: `journalctl -u 'fluxer-ha-*'` (add yourself to the `adm` group to read them without sudo), and `fluxer-ha/state/dns.log`. `fluxer-ha status` gives a summary. Run every `fluxer-ha` command as the account that installed Fluxer; it refuses root unless you pass `--allow-root`.

## Hooks

Two optional programs of yours, in `~/fluxer/fluxer-ha/hooks/`. The controller runs them when this site's role changes:

| Hook | When | Argument |
|---|---|---|
| `on-primary` | after it has started the app tier on the new primary | the site's name (`site1`, `site2`) |
| `on-replica` | after it has stopped the app tier on a demoted site | the same |

- **How they run:** as you, from `~/fluxer`, inside the controller's systemd sandbox (lab, 2026-10-16: uid 1000 and `cwd=/home/debian/fluxer`, at every switchover and failback).
- **They must be quick.** Each gets `FLUXER_HA_HOOK_TIMEOUT_SECONDS` (default 60) and is then killed. A hook that fails or times out sends an alert. The limit is there because the controller's loop waits for the hook, and that loop is what stops the app tier when this site stops being primary. Lab: an `on-primary` that hung was killed after the 5 s set for the test (exit 124), the alert arrived, and on the switch back that controller stopped its app tier as usual.
- **Nothing depends on them.** Failover works without them. Use them for what fluxer-ha doesn't do, such as telling a monitoring system or reindexing search.
- `install` creates the directory and never writes into it. `leave` keeps it (it's inside `fluxer-ha/`).

The DNS `exec` hook is separate: see [dns.md](dns.md).

## Monitoring

Set up two things. Without them you won't know when you've lost redundancy.

1. **`FLUXER_HA_HEARTBEAT_URL`, a dead-man's switch.** The **spare** pings it every 30 s, but only while every condition for an automatic failover holds:
   - it's the synchronous standby;
   - etcd has 3 of 3 members;
   - Valkey and the media mirror are healthy;
   - the controller is running and the clock is fine;
   - both sites run the same configuration;
   - DNS points at the primary;
   - the firewall is in place.

   Alert when pings stop for 2 minutes. That alert means "no automatic failover possible right now", which also covers the spare itself being down.
2. **`FLUXER_HA_ALERT_URL`.** Each event is POSTed to it: role changes, DNS failures, failbacks, a firewall that had to be re-applied, a clock gate holding the app tier.

Also probe the public URL (`/api/_health`) from outside, as you would for a single site.

## Planned switchover

```sh
fluxer-ha switchover            # to the other site, only if it's the sync standby
```

Zero-loss, with about 20–35 s of user-visible disruption, mostly the DNS TTL. On the preferred site, failback brings the primary back after the stability window; to stay on the other site, run `fluxer-ha hold` on the **preferred** site first, and `fluxer-ha release` later.

## Image versions and pinning

Three things decide which image each container runs:

| Images | How they're pinned | Your part |
|---|---|---|
| **fluxer-ha's own:** etcd, rclone (`s3-mirror`), the Postgres base the Patroni image is built on, and the alpine image its checks run | **Always by digest**, in `compose/ha.compose.yml`, `witness/compose.yml`, `patroni/Dockerfile` and its scripts. Not optional | None. A new fluxer-ha release moves them ([below](#upgrading-fluxer-ha-itself), [security.md](security.md) S22) |
| **Fluxer's** (api, gateway, worker and the other 9) | By **tag**: `FLUXER_IMAGE_TAG` in `fluxer-ha/.env.shared`, upstream's default `v1`, which **moves** with each release | Keep `v1`. A release tag doesn't pin a release: each Fluxer image is tagged on its own when it's built, so a given release tag exists for some images and not others (lab F4; upstream's upgrading docs say each image gets its own tag) |
| **The infrastructure from upstream's compose file:** valkey, nats, meilisearch, seaweedfs, caddy (the edge), livekit | By the **version tag** in `docker-compose.yml`, which changes only when the stack files do | None; `upgrade-fetch` brings the new files |

**The image lock, `fluxer-ha/ha.images.lock.yml`, is optional and recommended.** `fluxer-ha pin` writes it: a Compose overlay that names every image above (all but the Patroni image, which is built on the site) by the digest this site has pulled. With it last in `COMPOSE_FILE` on both sites:
- **Same bytes everywhere:** both sites, and any host you rebuild later, run byte-identical images. A tag that moves on the registry changes nothing until you pin again.
- **Checked:** the two sites compare their locks along with `.env.shared`, and the spare's health check fails while they differ.
- **The cost:** an upgrade takes one more step (pin, then copy the lock).

Without it, each site runs whatever `v1` pointed at when that site last pulled. Nothing notices the two sites running different builds, so always pull on both in the same step. `fluxer-ha rollback` works either way.

**Turning the lock on:**
1. On one site: `fluxer-ha pin`. It pins what that site runs now; `--pull` pulls the newest first.
2. Copy it to the other site byte for byte, for example from your workstation: `scp -3 site1:fluxer/fluxer-ha/ha.images.lock.yml site2:fluxer/fluxer-ha/`.
3. On both sites: add `:fluxer-ha/ha.images.lock.yml` to the **end** of `COMPOSE_FILE` in `fluxer-ha/.env.site`, then `fluxer-ha/build-env.sh`.
4. The rollout: `fluxer-ha rollout` on the spare, `fluxer-ha switchover`, `fluxer-ha rollout` on the other site. The images stay the same, but their references change, so Compose recreates the containers. Until the rollout, the health check reports "configuration not applied".

**Turning it off:** take `:fluxer-ha/ha.images.lock.yml` out of `COMPOSE_FILE` in `fluxer-ha/.env.site` and delete the file, on both sites; `fluxer-ha/build-env.sh` on both; then the same rollout.

`fluxer-ha pin` writes a new timestamp at the top of the lock every time, so the hash changes even when no digest does: always copy it.

**Lab:** on, drift, a pinned release, its rollback and off, each through the full rollout with writes running: **0** lost, both sites on the same digests at every step. A lock edited on one site failed the spare's health check until it was put back. The rollback pulled the old digest back from the registry, because the old image had already left the hosts (F48). Details in [lab-results.md](lab-results.md#upgrades-pinning-and-rollback).

## Upgrades

**The controller never applies a change by itself.** Nothing reaches the containers until `fluxer-ha rollout`, which runs only on the spare, so every change goes the same way: the spare, a switchover, then the other site. Read the release notes first ([upstream's releases](https://github.com/fluxerapp/fluxer/releases)). Hold failback for the duration if it might move the primary in the middle (`fluxer-ha hold` on the preferred site, `fluxer-ha release` after).

### Upgrading Fluxer without the image lock

1. **Both sites:** `fluxer-ha upgrade-fetch --ref main`. For `v1`, upstream's stack files come from `main`; for anything else, pass the ref the release notes give. It fetches the stack files and shows which changed. It keeps the old files, the tag, the lock and the images this site runs in `fluxer-ha/upgrade/<time>/`, for `fluxer-ha rollback`, and refuses a Postgres major-version change. Nothing restarts.
2. **Both sites, in the same step:** `docker compose --profile app pull` in `~/fluxer`. Nothing restarts.
3. **The spare:** `fluxer-ha rollout --dry-run` shows what it would recreate; then `fluxer-ha rollout`. It refuses on the primary. It recreates one service at a time and waits for each to be healthy: etcd (only if the other two members are healthy), Postgres (until it's the sync standby again), the rest of the data tier, then the warm tier. The app tier is **created with the new version but not started**. Last, a **full media sync** from the primary, with no time limit (see below).
   **The media sync** prints its progress every 30 s and ends the rollout:
   - **Objects skipped as unreadable** don't fail it (see "s3-mirror stops, or skips objects"). Everything else is copied.
   - **It stops with an error only if the copy makes no progress** for `FLUXER_HA_S3_MIRROR_STALL_SECONDS` (default 300): usually this site can't reach the primary's S3. By then every service is rolled out. Fix the cause and run `fluxer-ha rollout` again: services already on the new configuration aren't recreated, and the copy skips what's already here.
   - **How long it takes** depends on the bandwidth between the sites. A rough guide: about 7 minutes per GB at 20 Mbit/s, or 1.5 minutes per GB at 100 Mbit/s. A spare that's already in sync only compares listings.
4. `fluxer-ha switchover`. The new primary's API applies any schema changes as it starts.
5. **The new spare:** `fluxer-ha rollout`. Until you do, its health check fails with "configuration not applied on this site", so your heartbeat alerts and **failback won't move the primary onto it**.
6. Failback brings the primary home after its window (or `fluxer-ha switchover` back yourself).

### Upgrading Fluxer with the image lock

1. **Both sites:** `fluxer-ha upgrade-fetch --ref main`, as above. It keeps the old lock too.
2. **One site:** `fluxer-ha pin --pull`. It pulls what the tags point at **now** (ignoring the old lock, which would pull the old digests: lab F33) and writes the new lock.
3. **The other site:** copy the new lock over (`scp -3 site1:fluxer/fluxer-ha/ha.images.lock.yml site2:fluxer/fluxer-ha/`), then `docker compose --profile app pull`. That pulls exactly the digests in the lock. Until the copy, the two locks differ and the spare's health check says so.
4. to 7. As steps 3 to 6 above: rollout on the spare, switchover, rollout on the other site, failback.

### Changing a setting

Edit `fluxer-ha/.env.shared` identically on both sites (or `fluxer-ha/.env.site` on one), `fluxer-ha/build-env.sh` on each site you changed, then the rollout: the spare, switchover, the other site. The two `.env.shared` must be byte-identical; the spare's health check fails while they differ.

### Upgrading fluxer-ha itself

1. **All three hosts:** the new version of this repository in place of the old (`git pull` in your checkout, or a new release).
2. **The spare, then the primary:** `cd ~/fluxer && ~/fluxer-ha/fluxer-ha install site`, from **your checkout**: the `fluxer-ha` on your `PATH` is the installed copy of the old version, and would install itself again. It updates the scripts, the units and the root-owned copies in place, and restarts the controller without touching a container. A version with a new layout moves its files itself and says so (as on 2026-10-16).
3. **The witness:** `~/fluxer-ha/fluxer-ha install witness` (the checkout's, again), then `docker compose up -d` in `~/fluxer-witness` if its etcd pin changed.
4. **If the release changed the HA overlay, an image pin, the Patroni files or `s3-mirror.sh`** (its notes say so; `fluxer-ha rollout --dry-run` on the spare shows it, and the spare's health check names `s3-mirror(script)` for the last): `docker compose build postgres` on both sites if the Patroni files changed, then the rollout: the spare, switchover, the other site. An etcd or Patroni major version has its own order (below).

**From a version before 2026-10-16,** `install site` moves the old layout itself:
- **files at the top of `~/fluxer`** (`ha/`, `.env.shared`, `.env.site`, `ha-init/`, `ha.compose.yml`, ...) and its state in `/var/lib/fluxer-ha`: it moves them all into `~/fluxer/fluxer-ha/` and rewrites `COMPOSE_FILE`. Run it on the spare first, then on the primary. On each, it stops the controller and timers for the move only and starts them again. Then, as it tells you, `fluxer-ha rollout` on the spare, `fluxer-ha switchover`, and `fluxer-ha rollout` on the other site, because Patroni's build path changed;
- **from a root-only version:** it first takes ownership of that version's root-owned files (one `[root] chown` each), then moves them. It also moves the SSH key out of `/root/.ssh` and switches the services to your account;
- **a DNS hook in the old `ha/hooks/`** moves with it, and `FLUXER_HA_DNS_HOOK` is rewritten. Until the other site has moved too, the two `.env.shared` differ on that line and the spare's health check says so; it clears once both have moved.

Both were tested in the lab with writes running: 0 acknowledged writes lost.

### Moving the Fluxer directory

On the **spare**, with failback held, from the old directory:
1. `sudo systemctl stop fluxer-ha-controller.service fluxer-ha-health.timer fluxer-ha-failback.timer fluxer-ha-certs.timer`
2. `docker compose --profile app down` (the primary carries on alone meanwhile), then move the directory.
3. In the new one: `~/fluxer-ha/fluxer-ha --dir <new directory> install site`, which records the new path and re-renders the units.
4. Start the data and warm tiers from there: `. fluxer-ha/tiers.sh && docker compose up -d --no-deps $DATA && docker compose up -d --no-deps $WARM`, then `sudo systemctl start fluxer-ha-health.timer fluxer-ha-failback.timer fluxer-ha-certs.timer`.
5. Once it's the sync standby: `fluxer-ha rollout`.

For the other site, switch over and do the same there. Lab, 2026-10-17: site 2 moved from `~/fluxer` to `~/docker/fluxer`, healthy, then primary after a switchover, with the real messages and attachments read back through it byte for byte.

### Undoing an upgrade

**`fluxer-ha rollback`, on each site,** then the rollout as for any change (the spare, switchover, the other site). It works from the records an upgrade leaves:
- **Files and the image tag:** `upgrade-fetch` keeps the stack files it replaced, the old `FLUXER_IMAGE_TAG` and the old image lock in `fluxer-ha/upgrade/<time>/`. Upstream's `install.sh --update` keeps the old stack files and tag in `~/fluxer/backups/record-<time>/`. `rollback` takes the newest of the two, or the one you name with `--files <dir>`.
- **Images:** this works for a moving tag such as upstream's `v1` too. Every `rollout` first writes down the image each container on that site runs, in `fluxer-ha/upgrade/rollout-<time>/`, in install.sh's record format plus the registry digest. `rollback` uses the first one made after the files record: it holds the versions the upgrade replaced. From an install.sh record it takes that record's images first, then the rest from the rollout record. On a site that hasn't rolled out yet, it uses what its containers still run. It re-tags each reference back to its old image ID. If the old image has left this host, it pulls it back by digest. On Docker's containerd image store, the default since Docker 29, that's every time: an image's ID there is its registry digest, and a pull that moves a tag drops the old image's local entry at once (lab F48). Images pinned by digest (the HA overlay, the image lock) come back with the files instead.
- **It shows the plan first** and asks you to type `rollback` (`--yes` skips that). Nothing restarts. Afterwards the two `fluxer-ha/.env.shared` must match again, as after any change.

**Lab, 2026-10-16:** a simulated release (every Fluxer image rebuilt under the same `v1` tag, and a changed `docker-compose.yml`) went out and was rolled back this way. `rollback` pulled the 12 original images back by digest in 13 s per site, and the rollout put every container back on its original image, losing **0** of 1,944 writes.

**After the switchover onto the new version,** the database may carry its schema changes. Roll back then only if the release notes say the schema is backward compatible; otherwise roll forward.

**Not upstream's `install.sh --rollback`.** On an HA site it re-tags the images in its record one by one and stops with exit 3 at the first digest-pinned HA image (`refusing to create a tag with a digest reference`). The ones before it in its list stay moved back; it hasn't restored its files or restarted anything. (In the lab's record, seaweedfs, the Patroni image, meilisearch and nats came first.) If you've run it, `fluxer-ha rollback --files ~/fluxer/backups/record-<time>` finishes the job properly. It can't be made to work as it is: its record holds only the infrastructure images, because under HA the app tier sits in a profile it never enables, and it recreates the stack on that site without the rollout's checks. Making it stop failing would mean giving up the HA overlay's digest pins (security.md S22).

### Upstream's install.sh on an HA site

**Upstream's `install.sh --update` works on the spare, but only for part of the job** (tested in the lab). Use it there, never on the primary, as the user who owns `.env`, with failback held (`fluxer-ha hold`):
- **What it does:** a full backup (database dump, uploads, `.env`, stack files) into **`~/fluxer/backups/record-<time>/`**, upstream's own directory, separate from `fluxer-ha/backups/`; refreshed stack files; updated infrastructure images; and a recreate of this site's data tier. In the lab it finished in 56 s with no effect on the primary.
- **With fluxer-ha's files in `fluxer-ha/` (lab, 2026-10-16):** it accepts the overlays named there in `COMPOSE_FILE` (it only requires the first file, `docker-compose.yml`, to be directly in `~/fluxer`). Every file under `fluxer-ha/` was byte-identical afterwards, `.env` was unchanged, your own Caddy kept running and the edge stayed down. With writes running on the primary: **0** failed and **0** lost, no edge outage.
- **With the image lock:** its pull fetches the lock's digests, so it moves no image at all; the lock decides. Pin again to move them ("Upgrading Fluxer with the image lock").
- **What it doesn't do:** **upgrade Fluxer itself.** Under HA every Fluxer service is in the `app` profile, which the installer never enables, so it sees only the 10 infrastructure images. Carry on from step 2 above (pull with `--profile app`, `fluxer-ha rollout`, switchover).
- **What to watch for:**
  - **Secrets:** `install.sh --update` writes three secrets straight into `.env` when they're missing or `CHANGE_ME`: `FLUXER_ERLANG_COOKIE`, `FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64` and `FLUXER_PROFILE_PSEUDONYM_SECRET`. Under HA `.env` is generated, so copy any such key into `.env.shared` on **both** sites, with the same value, before anything rebuilds `.env`. Two checks hold you to that:
    - **`fluxer-ha/build-env.sh` refuses** to rebuild a `.env` that holds keys or values found in neither `.env.shared` nor `.env.site`, and names the keys, never the values. `--discard-env-edits` drops them on purpose.
    - **The spare's health check fails** with ".env was edited directly" until they're moved.
  
    Lab, 2026-10-16: with `FLUXER_PROFILE_PSEUDONYM_SECRET` taken out of the spare's `.env`, `install.sh --update` wrote a new value and said so, the health check failed naming the key, `build-env.sh` refused, and `--discard-env-edits` put back the shared value.

    Any other new required key isn't written by `install.sh` at all: Compose stops and names it, and you add it to `fluxer-ha/.env.shared`.
  - **The primary:** never run it there (the table below says what happens).

**Every `install.sh` flag on an HA site** (upstream's installer at `51ef7393c`, and before that `c0f825ae2`; each run on the lab pair on 2026-10-17 with writes and real messages going, unless the last column says otherwise). Since `51ef7393c` (upstream #3478), the uploads copy starts again only the containers that were running before it, with `docker start`, where it used to run `docker compose up -d --remove-orphans`:

| Flag | On an HA site | |
|---|---|---|
| (none: a new install) | Refuses: `.env exists. Run with --update to upgrade the instance and keep the secrets.` Nothing changes | lab |
| `--update` | **The spare only**, as the user who owns `.env`, failback held. It takes its backup, refreshes the stack files, pulls and recreates the **infrastructure** (not Fluxer: the app tier is in a profile it never enables), and writes any missing secret into `.env`, which the guard catches | lab |
| `--update` on the **primary** | **Never.** Lab: its uploads copy runs `docker compose stop` (the whole data tier, Postgres included), so Patroni fails over (edge outage 12 s, a real client's writes back in 36 s, 0 lost). With `51ef7393c` it then **starts the old primary's `edge` and `api` again**, as they were running before the copy, 21 s after that site was demoted: both sites answered for 4 s until the controller stopped them (its database was already a read-only replica, so nothing could be written there). It exited 0. (With `c0f825ae2` it waited 600 s for the stack and exited 6, and `s3-mirror` was stuck: F50.) | lab |
| `--no-volume-backup` | Database dump only, no uploads copy and so no `compose stop`: no impact, 0 lost. The gentler choice on the spare | lab |
| `--no-volume-compression` | The uploads copy as an uncompressed `.tar`. It still stops that site's stack for the copy, harmless on the spare (0 lost). Afterwards exactly what ran before is running again: the data and warm tiers, none of the cold one | lab |
| `--skip-backup-accept-data-loss` | No dump and no copy. Its record (images, tag, stack files) is still written, and `fluxer-ha rollback --files` works from it | lab |
| `--backup-dir <path>` | The record goes there. `fluxer-ha rollback` looks only in `~/fluxer/backups`, so pass `--files <that dir>/record-<time>`, which works | lab |
| `--ref <ref>` | The stack files come from that ref. Give the other site the same files (`fluxer-ha upgrade-fetch --ref <same ref>`) | lab (default ref only: the lab's installer copies the files locally) |
| `--image-tag`, `--tls`, `--edge-bind`, `--domain`, `--email` | **Ignored with `--update`** (lab: `--image-tag 2026.1014.114813` left `FLUXER_IMAGE_TAG=v1`). Under HA, change the tag with `fluxer-ha upgrade-fetch --tag`, or `FLUXER_IMAGE_TAG` in `fluxer-ha/.env.shared` on both sites. Changing the TLS mode under HA isn't supported | lab (`--image-tag`) |
| `--dry-run` | Safe on either site: it downloads into a temporary directory and only prints. Lab: every file under `~/fluxer` byte-identical afterwards. Its plan is upstream's (`compose pull`, `up -d`), not what fluxer-ha does | lab |
| `--rollback` | Stops part-way ([Undoing an upgrade](#undoing-an-upgrade)); use `fluxer-ha rollback` | lab |
| `--no-start` | Refused with `--update`: `--no-start belongs to an install.` | lab |
| `--non-interactive`, `--help` | As upstream | lab (`--non-interactive`) |
| `--engine podman` | Not with fluxer-ha: its firewall is Docker's `DOCKER-USER` chain | fluxer-ha's design |
| `--allow-root` | Only if fluxer-ha was installed with `--allow-root`. Lab: run as root, it left `.env` owned by root, mode 600; the services couldn't read it and the spare's health check failed. `sudo chown <you>: ~/fluxer/.env` and `fluxer-ha/build-env.sh --discard-env-edits` repaired it | lab |

**So the upgrade is fluxer-ha's** (the table at the top of this section): `upgrade-fetch` on both sites, the pull, `rollout` on the spare, switchover, `rollout` on the other. `install.sh --update` on the spare first is optional and adds only its backup. For the database alone, a `pg_dump` from either site does the same job.

### Moving an existing pair to etcd 3.6 and Patroni 4.1

This repository's pins since 2026-10-16. The order matters, because etcd 3.5.28+ and 3.6.9+ require authentication for reads that Patroni before 4.1.1 makes without it:
1. **Patroni first.** Patroni 4.1.5 works with the old etcd. Build the new image on both sites, then rollout, switchover, rollout as above.
2. **etcd to the latest 3.5 (v3.5.34).** Then `rollout` on each site (the spare first, so one member at a time), and on the witness `~/fluxer-ha/fluxer-ha install witness && docker compose up -d` in `~/fluxer-witness` (the checkout's copy, which has the new pin). Two members stay up throughout.
3. **etcd to 3.6.15,** the same way.

**Lab, 2026-10-16:** a pair installed on etcd 3.5.17 with Patroni 4.1.5 went 3.5.17 → 3.5.34 → 3.6.15 this way, with writes running. etcd stayed healthy throughout, and **0** acknowledged writes were lost (edge outage 3.0–4.5 s at each switchover). The cluster version moved to 3.6.0 only once all three members ran 3.6. From then on etcd can't go back to 3.5.

## When the spare is down

The primary carries on. What to expect:

| | |
|---|---|
| **Users** | No outage. Writes **pause for about 10–15 s** when the spare disappears, while the primary waits for it to time out (`wal_sender_timeout` 10 s), then continue. In the lab this happened for a power-off and for an isolation alike. A graceful shutdown of the spare's host paused writes for about 3 s, because `fluxer-ha install` orders Docker after WireGuard so Patroni leaves cleanly (11 s without that). Stopping only the spare's Postgres container caused no pause. |
| **Failover** | None. The primary site plus the witness are 2 of 3 votes. |
| **Your monitor** | The heartbeat stops: no automatic failover is possible until the spare is back. |
| **Protection** | Until the spare is back in sync, **RPO isn't zero and there's no automatic failover**. If the primary also dies now, the spare won't promote itself when it returns: it isn't the sync standby, and promoting it would lose the commits it missed. See below. |
| **Return within a day** | It catches up by streaming. Patroni keeps its replication slot, and with it the WAL it needs, for `member_slots_ttl` (24 h), capped at 10 GB by `max_slot_wal_keep_size`. Valkey resyncs, media sync resumes, and a rebooted spare starts no app services. |
| **Return after longer, or past the cap** | The primary has recycled WAL the spare needs, and Postgres retries for ever; Patroni doesn't fix that by itself. `ha-health.sh` on the spare notices ("requested WAL segment … has already been removed" while not streaming) and **re-clones it from the primary**: at most once an hour, with an alert. Re-cloning copies the whole database over WireGuard, so it takes as long as that copy. |

### The spare came back, but the primary is dead

The spare is behind, so Patroni won't promote it on its own. In the lab it stayed a replica, waiting for the old primary, until told otherwise. Only promote it by hand if you accept losing what it missed, or if the old primary's disk is gone for good:

```sh
site2$ cd ~/fluxer && docker compose exec -T postgres /opt/patroni/bin/patronictl -c /etc/patroni.yml failover --candidate site2 --force
```

**Lab, 2026-10-16:** Patroni accepted this with `synchronous_mode` still on: there was no need to turn it off. The new primary was **missing every write acknowledged after the spare fell behind**: 557 of 557 in the drill. That's the trade-off you accept here. When the old primary was powered back on, it rejoined as a replica by itself, and **its extra commits were discarded**. It was sync standby again within about 20 s.

If the old primary might come back with its data, wait for it instead. It has the commits the spare doesn't.

### Primary and witness both lost

The spare has 1 of 3 votes and can't take over. That's the price of never having split brain. Do this only if you're **sure** the primary is gone: powered off at the provider, not just unreachable. If it's still running somewhere, you'd have two primaries.

**1. Make the spare's etcd a cluster of one, once.** On the spare (site 2 here):

```sh
cd ~/fluxer
cat > /tmp/force-new-cluster.yml <<'Y'
services:
  etcd:
    environment:
      ETCD_FORCE_NEW_CLUSTER: "true"
Y
docker compose stop etcd
COMPOSE_FILE="$(sed -n 's/^COMPOSE_FILE=//p' .env):/tmp/force-new-cluster.yml" docker compose up -d --no-deps etcd
docker compose exec -T etcd etcdctl member list </dev/null      # just this site now
docker compose up -d --no-deps etcd                              # again, without the flag
rm /tmp/force-new-cluster.yml
```

Patroni promotes the spare once the old leader key expires. In the lab that took **25 s**, with nothing lost, because the spare was the sync standby. The controller then starts the app tier and points DNS here.

**2. Bring the witness back,** when it's reachable again:
- on the new primary: `docker compose exec -T etcd etcdctl member add witness --peer-urls=http://<witness WireGuard IP>:2380`, which prints the member list to use;
- on the witness, in `~/fluxer-witness`:
  - set `FLUXER_HA_ETCD_INITIAL_CLUSTER` in `.env` to the printed list, and `FLUXER_HA_ETCD_INITIAL_CLUSTER_STATE=existing`;
  - wipe its old data: `docker compose rm -sf etcd && docker volume rm fluxer-witness_etcd-data`;
  - then `docker compose up -d`.

  Until you wipe it, the old member restarts in a loop; it's harmless, because the cluster no longer accepts it.

  **The same for a witness that is still a member but can't rejoin** (its log says `failed to publish local member to cluster through raft`, for example after restoring it from an older backup or snapshot): first `docker compose exec -T etcd etcdctl member remove <its id>` on a site (the id from `etcdctl member list`), then the steps above. Lab: it was healthy again within seconds.

**3. Bring the old primary back the same way:**
- `member add` it on the new primary;
- on it, add `FLUXER_HA_ETCD_INITIAL_CLUSTER_STATE=existing` to `.env.site`, run `fluxer-ha/build-env.sh`, and wipe its etcd: `docker compose rm -sf etcd && docker volume rm fluxer_etcd-data`;
- `docker compose up -d --no-deps etcd`.

Its Patroni doesn't wait for this. In the lab it had already rejoined as a replica on boot, finding the leader through the other members. It was sync standby **3 s** after its etcd came up, and started no app services.

**4. Put the witness's `FLUXER_HA_ETCD_INITIAL_CLUSTER` back to all three members,** then `docker compose up -d`. Leave `existing` in place; it only matters for an empty data directory.

Add members one at a time, waiting for each to be healthy. etcd refuses to add a member while an earlier one hasn't started, because the cluster would lose quorum.

**Lab, 2026-10-16:** the whole sequence above, with site 2 primary and site 2 and the witness powered off: promotion 25 s, then both members back, three healthy members, a sync standby, and `ha-health OK`.

## Valkey won't start

**Symptom:** after a hard power-off, a site's `valkey` container restarted in a loop, and `docker compose logs valkey` shows `Bad file format reading the append only file` (a damaged record) or `Internal error in RDB reading` (a damaged base RDB file). On the spare, its health check says `valkey link down`, failback waits, and **this site couldn't take over** while it lasts.

**Why:** upstream runs Valkey with an append-only file (`--appendonly yes --appendfsync everysec`). A power cut can damage it. Valkey recovers a cut-off end by itself, but not a damaged record or base file (lab F49).

**What fluxer-ha does:** `ha-health` (every 30 s, on both sites) repairs it, at most once every 10 minutes. It acts only on those errors, and only while Valkey isn't running: not, for example, when it ran out of memory. It always first copies the damaged files to **`fluxer-ha/errors/valkey-<time>/`**, then alerts with what it did:

| Site | Damage | Repair |
|---|---|---|
| spare | any | Valkey starts empty. It's a replica, so it copies everything from the primary's (lab: 15 s, 119 keys) |
| primary | a record in an `.aof` file | `valkey-check-aof --fix` on that file (upstream's procedure): everything before the damaged record is kept, what came after is lost |
| primary | the base RDB file, or the fix wasn't enough | Valkey **starts empty**: service rather than downtime. What it held is gone on that site (caches, sessions, rate limits); the copy in `errors/` is the only one |

Each folder has:
- `README.txt`: which site and role, what the repair did.
- `appendonlydir/`: the damaged files, as Valkey left them (and `dump.rdb`, if there was one).
- `valkey.log`: Valkey's last 200 lines before the repair.
- `valkey-check-aof.txt`: what the fix reported, when it ran.

They're mode 700, yours, and nothing deletes them: delete each once you've looked at it.

If the alert ends with `VALKEY STILL ISN'T RUNNING`, the repair didn't help: look at `docker compose logs valkey`.

**By hand**, the same steps (this is what it does on the spare):

```sh
cd ~/fluxer
docker compose stop valkey
mkdir -p fluxer-ha/errors/valkey-manual
docker run --rm -v fluxer_valkey-data:/data -v "$PWD/fluxer-ha/errors/valkey-manual:/out" alpine:3.24 \
  sh -c "cp -a /data/appendonlydir /out/ && chown -R $(id -u):$(id -g) /out && rm -rf /data/appendonlydir"
docker compose up -d --no-deps valkey
```

**Lab, with the real damaged file from F49:** on the spare, repaired in one health run (11 s), re-synced from the primary. On the primary, `valkey-check-aof --fix` cut 1,237 bytes from `appendonly.aof.3.incr.aof`, and Valkey started with its keys, writes back in 28 s. With a damaged base RDB, it started empty and running. (Pointed at a damaged RDB, `valkey-check-aof --fix` "fixes" it by cutting it to 0 bytes, so the repair never does that.)

## s3-mirror stops, or skips objects

**Symptom:** the spare's health check printed `ha-health WARNING: s3-mirror skips N unreadable object(s)`, and you got an alert naming them. Or `fluxer-ha rollout` ended with `the full media sync failed: … made no progress`.

**Why:** an object whose metadata is there but whose data can't be read. Reading it **hangs** rather than failing (lab F52: an upload written seconds before the primary's watchdog reset it; the client was never told it had been stored). rclone's own `--timeout` doesn't end such a hang (lab F50). Or the two sites can't reach each other's S3 at all.

**What fluxer-ha does:**
- **No time limit on a copy:** a long first copy, or a large file on a slow link, takes as long as it takes.
- **A limit on no progress:** an `rclone` run whose counters (bytes, files, checks, objects listed) haven't moved for `FLUXER_HA_S3_MIRROR_STALL_SECONDS` (default 300, in `fluxer-ha/.env.shared`) is stopped. The next run carries on where it stopped.
- **Searching for the unreadable objects:** after a run that stalled or failed, s3-mirror lists what the destination lacks (names and sizes only). If even that listing makes no progress, the link is the problem and it stops there. Otherwise it copies each object alone, and one that makes no progress for `FLUXER_HA_S3_MIRROR_OBJECT_STALL_SECONDS` (default 60), or fails, is skipped from then on. The rest of the bucket is mirrored.
- **Trying it again:** each reconcile (hourly, and each rollout) tries it again. One that's readable again, or deleted, isn't skipped any more. If the site can't be reached, it stays on the list.
- **Never deleting a skipped object:** the spare's hourly reconcile is an exact mirror, so it deletes what the primary no longer has. It never deletes an object the push-back to a new primary couldn't push: that one exists only on this site (an upload stranded by a failover), so it's kept and pushed again at each reconcile, never over an object the primary has (F53).

**Health:**
- **A skipped object doesn't mark the spare unhealthy,** so failover and failback aren't affected. You get a warning and an alert instead, whenever the list changes.
- **Anything else missing does:** the spare counts as healthy only if a full sync finished within the last `FLUXER_HA_S3_MIRROR_INTERVAL_SECONDS` + 10 minutes. Until then, failback won't move the primary onto it.
- **Automatic failover never waits for media.** If the primary dies, the spare takes over with what it has.

**What's kept:** `ha-health` copies each record to **`fluxer-ha/errors/s3-mirror/<time>-<primary|local>-<bucket>-<object>-<hash>/`**, one folder per finding, never reused (the object's name is cut to 80 characters there, and `<hash>` keeps two long names apart):
- `README.txt`: the bucket, the object, which site it was read from, and what rclone said.
- `filer-metadata.json`: SeaweedFS's own record of it, its chunks and their file IDs, from that site's filer. The data itself is what can't be read.

The current list is `docker compose exec s3-mirror cat /state/unreadable-primary-<bucket>.txt` (or `-local-` for the push-back to a new primary).

What to do with the object is your decision. To look at it on the site that has it:

```sh
cd ~/fluxer
R="docker compose run --rm --no-deps -T --entrypoint rclone s3-mirror"
timeout 30 $R cat local:<bucket>/<object> --s3-no-check-bucket </dev/null | wc -c   # 0 after 30 s: still unreadable
```

If no message refers to it, you can delete it there: `$R deletefile local:<bucket>/<object> --s3-no-check-bucket`. The next reconcile then stops skipping it. Or leave it: it costs a warning, and one try of up to 60 s per reconcile and per rollout.

**`filer-sync` retries it too,** forever, about 16 log lines a minute on the spare (`read part <file id> … 500 Internal Server Error`). That's harmless: new uploads still replicate while it retries (lab), and Docker caps the container's log at 3 × 10 MB. But within a few days those lines push everything else out of `docker compose logs filer-sync`, which is one more reason to delete the object once you've looked at it.

**Lab, with the real F52 object** replayed on a fresh install: the rollout's sync skipped it after 434 s (300 s without progress, then 80 s to find it), mirrored the rest of the bucket, kept the record in `errors/s3-mirror/`, and left the spare `ha-health OK` with one alert. Later rollouts took 108 s and 102 s, each with the 60 s retry. With the spare's mirror cut off from the primary's S3, the rollout stopped after 668 s with `made no progress for 300s (can this site reach the other site's S3?)`, and once the link was back, running it again finished. Details in [lab-results.md](lab-results.md#the-saved-damaged-files).

## Failback rolled back but failed

Failback switched over, the preferred site didn't serve, and the switch back failed too: the alert says `ROLLBACK FAILED`. The preferred site is primary but not serving. Look at `journalctl -u fluxer-ha-controller` and `docker compose ps` there. If you can't fix it quickly, `fluxer-ha switchover` back to the other site and `fluxer-ha hold`.

## Jobs left behind

Background jobs queued on a site's NATS stay there when the primary moves. Failback waits up to `FLUXER_HA_FAILBACK_JOBS_WAIT_SECONDS` for in-flight jobs to finish, then alerts and proceeds. The jobs run when that site is primary again.

## Leaving HA (back to a single site)

`fluxer-ha leave` takes the pair back to one site and **keeps every write made since `migrate`**. Run it on each host, in this order:

```sh
site2$ fluxer-ha leave      # the spare first
site1$ fluxer-ha leave      # the site you keep (the primary): a maintenance window
witness$ fluxer-ha leave
```

1. **On the spare:**
   - it refuses if this site is the primary; to keep site 2 instead, switch over first and swap the roles below;
   - **pauses Patroni for the whole cluster**, so nothing can fail over from here on;
   - stops this site's stack and removes fluxer-ha's system files (units, firewall rules, the Docker drop-in, the watchdog rule, the SSH account and its sudo rule, `fluxer-ha/state`);
   - keeps the volumes and the files in `~/fluxer`.
2. **On the site you keep:**
   - **Checks:** it refuses while the spare's Patroni still answers, or while the old pre-HA `postgres-data` volume still exists (stale data; delete it, or pass `--replace-old-volume`). It records the row count.
   - **The window starts:** the HA services and the app tier stop, and the database is dumped from Patroni into `fluxer-ha/backups/leave-ha-<time>.dump`.
   - **Builds a single-site `.env`:** this `.env` without any `FLUXER_HA_*` key or the HA `FLUXER_KV_URL`, with `COMPOSE_FILE` back to upstream's files plus any overlay of yours. With `--proxy-network`, your proxy keeps reaching the edge through `~/fluxer/proxy-network.compose.yml`, an overlay of yours from then on. It names the network itself, in the pattern upstream's reverse-proxy documentation gives for a proxy on a Docker network (refuses if a different file of that name is already there). Every other key stays, including any `install.sh` added. The HA `.env` is kept as `fluxer-ha/backups/.env.ha-<time>`.
   - **Swaps the database:** removes the HA containers, starts upstream's Postgres on a fresh volume, restores the dump and checks the row count. The data moves as a dump because upstream's Postgres is the Alpine image and Patroni's the Debian one: their text collation differs, so the data files must not be reused.
   - **The window ends:** `docker compose up -d` brings up upstream's stack, and the window closes once HTTPS answers.
   - **Cleans up:** it removes fluxer-ha's system files, as on the spare.
   - **Rolls back by itself** if anything fails before the restore checks out: the HA `.env` comes back, Patroni starts on its volume, and the cluster is resumed.
3. **On the witness:** it stops etcd and removes the firewall and the units.

**Only the Fluxer database moves** (`FLUXER_POSTGRES_DATABASE`), exactly as `migrate` moved only that one in. If you created other databases in Patroni yourself, dump them first.

DNS needs nothing: it already points at the site you keep. Delete these yourself once you're sure:
- the HA volumes: `patroni-data`, `etcd-data`, `s3-mirror-state`;
- **`~/fluxer/fluxer-ha/`**, which is everything else of fluxer-ha's in your Fluxer directory: the scripts, the settings, the overlays, `init/`, and `backups/` with the dump and `.env.ha-<time>`. Keep `~/fluxer/proxy-network.compose.yml` if `leave` made one;
- the `fluxer-ha` command (`/usr/local/share/fluxer-ha`, `/usr/local/bin/fluxer-ha`).

**Lab, 2026-10-16:** after `leave` with `--proxy-network`, no `FLUXER_HA_*` key was left in `.env`. With `fluxer-ha/` deleted, the stack still parsed, the edge stayed on the proxy's network, and upstream's `install.sh --update` treated it as an ordinary single-site instance (HTTPS 200 afterwards). All 3,000,000 seed rows were there.

Each step asks you to type `leave`; `--yes` skips that.

## Migration rollback

If `fluxer-ha migrate` stopped half-way, it rolled back by itself: your old `.env` and the old Postgres container are back, and the old volume was never touched. If it died before it could roll back (the host lost power, say), `fluxer-ha/.env.pre-ha` is still there. Then:

```sh
docker compose stop postgres etcd       # with the current .env
cp -p fluxer-ha/.env.pre-ha .env && docker compose up -d --remove-orphans
```

Then `rm fluxer-ha/.env.pre-ha` before trying again. The dump is in `~/fluxer/fluxer-ha/backups/`.
