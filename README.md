> **Disclaimer:** I'm a junior software engineer, and this project was created with the use of AI. I can't claim to be an expert. There was heavy oversight throughout, though, and it was tested extensively in a Proxmox lab ([docs/lab-results.md](docs/lab-results.md)).

# fluxer-ha

Two-site, automatic failover for a self-hosted [Fluxer](https://github.com/fluxerapp/fluxer) instance that runs on Docker Compose. It's built as a layer on top of an existing install: upstream's files stay as they are, and the HA parts (overlays, scripts, settings, state) live in one subdirectory, `fluxer-ha/`, of your Fluxer directory (wherever that is). Keep this repository's checkout somewhere else, such as `~/fluxer-ha`. The only upstream file it changes is `.env`, which it generates.

**Status: 0.1, tested in a lab, not yet in production.** Every number below comes from a disposable three-VM lab ([docs/lab-results.md](docs/lab-results.md)). Read [Limits](#limits) before relying on it.

## What you get

- **Two sites, one active.** Site 1 serves; site 2 is a warm spare that holds a synchronous copy of the database, Valkey and media. A small **witness** VM at a third location casts the deciding vote.
- **Automatic failover, no human.** If the primary dies or is cut off, the spare takes over: about **30–40 s** until writes work again after a hard power-off, a freeze or an isolation, **with no acknowledged write lost** in any lab drill.
- **No split brain.** Only the Patroni primary runs the user-facing app tier. An isolated old primary demotes itself, and the kernel watchdog resets it if it can't. In the lab an isolated primary acknowledged **0 writes** after being cut off.
- **Automatic failback.** Once the main site has been healthy for an hour, the primary moves back, with retries and back-off if that fails.
- **DNS failover** through Cloudflare (DNS only, no proxying), your own script, or none (a floating IP or load balancer).
- **Upgrades and setting changes one site at a time**, applied on the spare first, with about 20–35 s of disruption per switchover.

## How it works

```
         users ── DNS (TTL 60) ──► site 1 (primary)          site 2 (spare)
                                   ├─ edge + app tier         ├─ app tier stopped
                                   ├─ Postgres (Patroni) ═══► ├─ Postgres sync standby
                                   ├─ Valkey ──────────────►  ├─ Valkey replica
                                   ├─ SeaweedFS ───────────►  ├─ SeaweedFS (filer.sync)
                                   └─ etcd ─┐          ┌───── └─ etcd
                                            └─ witness ┘   (etcd: the third vote)
                       all of it over WireGuard between the three hosts
```

Patroni (with etcd) decides which site is primary. A small controller on each site follows Patroni: it starts the app tier, edge included, only where Postgres is the primary, and points DNS there. [docs/architecture.md](docs/architecture.md) has the details and the reasoning behind them.

## Requirements

- An existing Fluxer install from upstream's `install.sh`: Docker Compose, with the bundled Postgres, Valkey and SeaweedFS. Either TLS mode works: the bundled edge (default) or your own reverse proxy.
- **Run it as the account that installed Fluxer** (in the `docker` group), like upstream's installer, with `sudo` available. `fluxer-ha` refuses to run as root unless you pass `--allow-root`. Its few root steps (systemd units, the firewall, the watchdog device) go through `sudo` and are printed first; the services run as your account. [docs/security.md](docs/security.md#what-runs-as-root) has the full list.
- Two Linux hosts for the sites with systemd, Docker, Compose 2.24.4 or newer and Docker's iptables firewall backend. Tested on Debian 13 with Docker 29.9 and Compose 5.6, and only there.
- A **third** small VM at a **third** location for the witness. Without the third location, a single network fault can take both of the others offline together.
- WireGuard between all three (examples in [docs/install.md](docs/install.md)).
- A watchdog device on both sites (`softdog` is enough), and chrony.
- Low latency between the sites: every write waits for the spare (synchronous replication), so **each commit takes about one round trip between the sites, plus 4–8 ms**. The lab stayed stable up to 100 ms round trip, and a power-off failover at 60 ms worked as at 0.5 ms ([lab-results.md](docs/lab-results.md#latency-between-the-sites)). What's too slow for you depends on your instance's write load.

## Quick start

The full procedure, with checks and rollback at every step, is [docs/install.md](docs/install.md). In outline:

```sh
# all three hosts: WireGuard up, this repo checked out, then
./fluxer-ha doctor site            # or: doctor witness

# site 1, next to the running instance (nothing changes yet)
./fluxer-ha init --site1-wg 10.77.0.1 --site2-wg 10.77.0.2 --witness-wg 10.77.0.3 \
                 --site1-ip 203.0.113.10 --site2-ip 198.51.100.20 --dns cloudflare
# edit fluxer-ha/.env.shared (DNS, monitoring), then
./fluxer-ha bundle                 # site 2's files, from the edited settings
./fluxer-ha install site
# witness: install witness, put witness.env in place, witness-up
# both sites: ssh-link, exchanging keys
fluxer-ha migrate                  # site 1: a short maintenance window (1–1.5 min in the lab)
# site 2: unpack the bundle, install site, ssh-link, then
fluxer-ha join
fluxer-ha status
```

Then run the drills in [docs/testing.md](docs/testing.md) before you trust it.

## Day to day

| Task | Command | More |
|---|---|---|
| See what's going on | `fluxer-ha status` | [operations](docs/operations.md) |
| Planned switchover | `fluxer-ha switchover` | |
| Keep the primary where it is | `fluxer-ha hold` / `release` (on the preferred site) | |
| Upgrade Fluxer | `fluxer-ha upgrade-fetch` and a pull on both, then `rollout` on the spare, `switchover`, `rollout` on the other | [operations, "Upgrades"](docs/operations.md#upgrades) |
| Undo an upgrade | `fluxer-ha rollback` on both, then the same rollout | [operations, "Undoing an upgrade"](docs/operations.md#undoing-an-upgrade) |
| Change a setting | edit `fluxer-ha/.env.shared` on both, `build-env.sh`, then the same rollout | [operations, "Changing a setting"](docs/operations.md#changing-a-setting) |
| Pin every image by digest (optional, recommended) | `fluxer-ha pin`, copy the lock, add it to `COMPOSE_FILE` | [operations, "Image versions and pinning"](docs/operations.md#image-versions-and-pinning) |
| Every command and option | `fluxer-ha help` | [commands](docs/commands.md) |
| Upgrade fluxer-ha itself | `git pull`, then the checkout's `fluxer-ha install site` on each site and `install witness` | [operations, "Upgrading fluxer-ha itself"](docs/operations.md#upgrading-fluxer-ha-itself) |

Upstream's `install.sh --update` is safe on the **spare**, and gives you its backup and refreshed stack files. It can't upgrade Fluxer itself under HA, though, so `rollout` still does that part ([operations](docs/operations.md#upgrades)). **Never run it on the primary**: it stops that site's Postgres for its backup. Its `--rollback` doesn't work on an HA site: it stops part-way. Use `fluxer-ha rollback`, which reads install.sh's records ([operations](docs/operations.md#upgrades)).

## Limits

- **The witness is trusted.** It's an etcd member, so whoever controls it can steer Patroni, whatever the passwords ([docs/security.md](docs/security.md)). Keep it small and locked down.
- **RPO is zero only while the spare is in sync.** While the spare is down or behind, the primary carries on alone; if it then dies too, failover needs a person ([docs/operations.md](docs/operations.md#when-the-spare-is-down)).
- **Users notice a failover.** The DNS TTL (60 s) and client reconnects dominate what users see: about 30–90 s in the lab, depending on the resolver.
- **Voice calls drop** at a failover and reconnect to the new site.
- **Tested in a lab only:** real WAN latency and Let's Encrypt on both sites haven't been exercised yet. nginx was tested in front of a lab pair, Traefik only on its own.
- **Not supported:** an external Postgres, Valkey or object store, Cloudflare Tunnel, Kubernetes (upstream has a Helm chart for that).

## Licence

AGPL-3.0-or-later, like Fluxer. See [LICENSE](LICENSE).
