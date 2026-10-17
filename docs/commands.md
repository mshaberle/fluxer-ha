# The `fluxer-ha` command

```
fluxer-ha [--dir <fluxer dir>] [--allow-root] <command> [options]
```

Run it as the account that installed Fluxer (in the `docker` group). Steps that need root go through `sudo` and are printed with `[root]` first. Before `install`, run it from your checkout (`~/fluxer-ha/fluxer-ha`); after that, `fluxer-ha` is on your `PATH`. To update fluxer-ha itself, run the **checkout's** copy again ([operations.md](operations.md#upgrading-fluxer-ha-itself)).

## Global options

| Option | What it does |
|---|---|
| `--dir <fluxer dir>` | The Fluxer directory (the one upstream's `install.sh` created, with `docker-compose.yml`). Give it **before** the command. Without it: the directory recorded by `install` in `/etc/fluxer-ha/fluxer-ha.conf`, else the current directory. On the witness the default is `~/fluxer-witness`. |
| `--allow-root` | Permits running as root, like upstream's flag of the same name; it may come anywhere on the line. The services then run as root too. Without it, `fluxer-ha` refuses root. |
| `-h`, `--help`, `help` | Prints the usage text. |

## Set-up commands

In the order [install.md](install.md) runs them.

| Command | Where | What it does | Options |
|---|---|---|---|
| `doctor [site\|witness]` | every host | Checks this host and its Fluxer install. Changes nothing. Defaults to the installed role, else `site`. | — |
| `init <options>` | site 1 | Writes the HA settings into `fluxer-ha/` (`.env.shared`, `.env.site`, `init/`) from your `.env`. Nothing the running stack reads changes. Runs once: it refuses if `fluxer-ha/.env.shared` exists. | See [`init`](#init) |
| `bundle` | site 1 | Packs site 2's files into `fluxer-ha/init/site2-bundle.tar.gz`, after you've edited `.env.shared`. Run it again after any later edit, before site 2 joins. | — |
| `install site\|witness` | every host | Puts the HA files in `<fluxer dir>/fluxer-ha/` (or `~/fluxer-witness`), the systemd units (not enabled), the root-owned copies and the watchdog in place. Running it again updates this host in place and restarts the controller without touching a container. | — |
| `ssh-link [--peer-key '<key>']` | both sites | Sets up the restricted SSH link. Without `--peer-key`, prints this site's key. With it, installs the peer's key (exactly one `ssh-ed25519` line). | `--peer-key` |
| `witness-up` | witness | Starts the witness's etcd member and enables its firewall. | — |
| `etcd-up` | site 2 | Starts site 2's etcd member. Needed before `migrate`. | — |
| `migrate` | site 1 | Moves the running database under Patroni, in one short maintenance window. Rolls back by itself if anything fails before the restore checks out. | — |
| `join` | site 2 | Clones the database from site 1, waits until site 2 is the sync standby, starts the warm tier and enables the timers. | — |
| `leave [--yes] [--replace-old-volume]` | the spare, then the site you keep, then the witness | Back to a single site, keeping every write ([operations.md](operations.md#leaving-ha-back-to-a-single-site)). | `--yes` skips typing `leave`. `--replace-old-volume` lets it replace a leftover pre-HA `postgres-data` volume instead of refusing. |

### `init`

| Option | Required | What it is |
|---|---|---|
| `--site1-wg <IPv4>`, `--site2-wg <IPv4>`, `--witness-wg <IPv4>` | yes | Each host's WireGuard address |
| `--site1-ip <IPv4>`, `--site2-ip <IPv4>` | yes | Each site's public IPv4 address, which DNS will point at |
| `--dns cloudflare\|exec\|none` | no (default `none`) | How traffic moves to the new primary ([dns.md](dns.md)) |
| `--domain <name>` | no | The DNS record's name, if it isn't `FLUXER_DOMAIN`. The certificate is always for `FLUXER_DOMAIN`. |
| `--cert edge\|caddy\|none` | no | Where the certificate lives. Default: `edge` with bundled TLS, `caddy` with `--tls proxy` ([reverse-proxies.md](reverse-proxies.md)). |
| `--proxy-network <network>` | no | With `--tls proxy` and a reverse proxy in Docker: puts the edge on that Docker network (as in `caddy_default`) |
| `--wg-interface <name>` | no (default `wg0`) | The WireGuard interface, run by `wg-quick@<name>` |

## Day-to-day commands

| Command | Where | What it does | Options |
|---|---|---|---|
| `status` | either site | Roles, replication, health, failback state | — |
| `switchover [--to <site>]` | either site | A planned, zero-loss switchover. It refuses unless the target is the sync standby. | `--to site1\|site2`; default: the other site |
| `hold` | the preferred site | Stops automatic failback (writes `fluxer-ha/state/failback.latched`) | — |
| `release` | the preferred site | Allows failback again, and clears its back-off | — |
| `rollout [--dry-run]` | **the spare only** | Applies configuration and image changes to this site's containers, one service at a time, ending with a full media sync ([operations.md](operations.md#upgrades)) | `--dry-run` shows what it would recreate |
| `pin [--pull]` | one site | Writes the image lock, `fluxer-ha/ha.images.lock.yml`, from the digests this site has ([operations.md](operations.md#image-versions-and-pinning)) | `--pull` pulls what the tags point at now first |
| `upgrade-fetch --ref <ref>\|--from <dir> [--tag <tag>]` | both sites | Fetches upstream's stack files at `<ref>` and shows what changed. It keeps the old files, tag, lock and image list in `fluxer-ha/upgrade/<time>/` for `rollback`, and refuses a Postgres major-version change. Nothing restarts. | `--ref` the git ref (`main` for `v1`). `--from <dir>` takes the files from a local directory instead of downloading. `--tag` also sets `FLUXER_IMAGE_TAG` in `.env.shared`. |
| `rollback [--files <dir>] [--yes]` | each site | Undoes an upgrade on this site: the files, the tag and the images, from the newest record ([operations.md](operations.md#undoing-an-upgrade)). Nothing restarts; then roll out as for any change. | `--files` names the record (a `fluxer-ha/upgrade/<time>` or `backups/record-<time>` directory). `--yes` skips typing `rollback`. |
| `version` | any | Prints the version | — |

## Scripts in `fluxer-ha/`

Run from the Fluxer directory, as the same account.

| Script | What it does |
|---|---|
| `fluxer-ha/build-env.sh [--discard-env-edits]` | Rebuilds `.env` from `.env.shared` and `.env.site`. It refuses if `.env` holds keys or values found in neither (it names the keys, never the values); `--discard-env-edits` drops them on purpose. |
| `fluxer-ha/ha-health.sh` | The health check the timer runs every 30 s; prints `ha-health OK`, warnings, or what failed |
| `fluxer-ha/etcd-auth.sh users` | Re-applies the etcd users after you change their passwords, before the rollout ([security.md](security.md#secrets)) |
| `fluxer-ha/tests/gd-*.sh` | The drills; each needs `HA_GAMEDAY=1` and a typed confirmation ([testing.md](testing.md)) |
| `fluxer-ha/tests/gd-collect.sh "<start time>"` | Saves the cluster state and logs after a drill, to `fluxer-ha/state/evidence/` |
| `tests/probe.mjs`, `tests/analyze.mjs` | The external probe and its analyser, run from your checkout ([testing.md](testing.md)) |

The rest (`controller.sh`, `failback.sh`, `dns-failover.sh`, `sync-edge-certs.sh`, `s3-mirror.sh` and the others) are run by the systemd units and containers, not by hand.
