# Installing fluxer-ha

This takes an existing single-site Fluxer install and turns it into a two-site pair with a witness. Your instance keeps running until `migrate`, which needs one short maintenance window: 56–92 s in the lab with a 227 MB database. The time grows with the size of the database dump.

**The order, at a glance.** Each step says on which host it runs.

| Step | Where | What |
|---|---|---|
| 0 | all three | Packages, ports, this repository |
| 1 | all three | WireGuard |
| 2 | your DNS provider | The record, the TTL, a token |
| 3 | all three | `fluxer-ha doctor` |
| 4 | site 1 | `init` writes the settings; you edit `fluxer-ha/.env.shared`; `bundle` |
| 5 | site 1 | `install site` |
| 6 | witness | `install witness`, `witness-up` (any time before step 10) |
| 7 | site 2 | Your reverse proxy (with `--tls proxy` only), unpack the bundle, `install site` |
| 8 | both sites | `ssh-link` |
| 9 | site 2 only | `etcd-up` |
| 10 | site 1 | `migrate` (the maintenance window) |
| 11 | site 2 | `join` |
| 12 | both sites | `status`, then the drills |
| 13 | both sites | Clean up what the migration kept for rollback |

Read [architecture.md](architecture.md) first, so the steps make sense.

**Host names in the commands.** `site1`, `site2` and `witness` in commands such as `scp site1:… site2:` are your **workstation's** SSH names for the three hosts: add them to `~/.ssh/config` (with `HostName` and `User`), or type `user@address` instead. fluxer-ha itself never looks a host up by name: everything between the hosts uses the WireGuard addresses you give `init`, so nothing goes in `/etc/hosts`.

**Where it puts things.** Your Fluxer directory can be anywhere; these docs call it `~/fluxer`, so `cd` into yours instead (the two sites' needn't match: the lab ran one from `~/docker/fluxer` and the other from `~/fluxer`). In it, fluxer-ha keeps everything it writes in **one subdirectory, `~/fluxer/fluxer-ha/`**: its scripts, the settings files, the overlays, its state and its backups. It changes only one file of upstream's: `.env`, which it rebuilds from its settings files (step 4). Outside the Fluxer directory, `install` writes the system files that have to live elsewhere (systemd units, the firewall's and the SSH gate's root-owned copies, the watchdog rule), listed in [security.md](security.md#what-runs-as-root). After the install, `~/fluxer` looks like this:

```
~/fluxer/
├── .env                      rebuilt by fluxer-ha/build-env.sh; don't edit it
├── docker-compose.yml        upstream's stack files, untouched
├── docker-compose.proxy.yml    (with --tls proxy)
├── Caddyfile, .env.example, ...
├── backups/                  upstream install.sh --update's records, if you run it
└── fluxer-ha/
    ├── .env.shared           settings both sites share (byte-identical)
    ├── .env.site             this site's own settings
    ├── .env.built            what build-env.sh last wrote, so it can tell edits apart
    ├── ha.compose.yml        the HA overlay, named in COMPOSE_FILE
    ├── ha.proxy-network.yml  (with --proxy-network)
    ├── *.sh, dns/, patroni/, tests/   the scripts the services run
    ├── hooks/                yours: on-primary, an exec DNS hook (install never overwrites it)
    ├── init/                 init's output: site 2's files and the bundle (site 1)
    ├── backups/              migrate's and leave's dumps (mode 700; made by migrate)
    ├── upgrade/              what fluxer-ha rollback works from: upgrade-fetch's copies of the
    │                         files, tag and images it replaced, and each rollout's record of
    │                         the images that ran before it (made on first use)
    └── state/                the services' state, the SSH key, drill evidence (mode 700)
```

## Who runs it

Like upstream's `install.sh`, `fluxer-ha` refuses to run as root. Run every command as **the account that installed Fluxer**, the one in the `docker` group that owns `~/fluxer/.env`. On site 2 and the witness, use an account in the `docker` group too, ideally with the same name. (After `usermod -aG docker <you>`, log out and back in.) That account needs `sudo` rights; `sudo` asks for its password for the `[root]` steps.
- **Root steps:** the few steps that need root go through `sudo`, and each is printed with `[root]` first, so you see exactly what's elevated. They're systemd units, the firewall, the watchdog device, and the SSH gate's account and sudo rule.
- **The services:** they run as that same account.
- **Root instead:** `--allow-root` permits running as root, as upstream's flag does: `sudo fluxer-ha --allow-root <command>`. Then the services run as root too.

[security.md](security.md#what-runs-as-root) lists exactly what runs as root.

## 0. What you need

| Host | Role | Needs |
|---|---|---|
| **site 1** | Your current server. It becomes the first primary, and the **preferred** site that failback returns to. | Your running Fluxer, from upstream's `install.sh` |
| **site 2** | The warm spare. Same size as site 1: it runs everything after a failover. | Docker, Compose 2.24.4+, nothing of Fluxer's yet |
| **witness** | One etcd member, the deciding vote. **At a third location.** | 1 vCPU, 1 GB RAM, Docker |

On all three: `docker`, the `docker compose` plugin, `curl`, `openssl`, `sudo`, WireGuard, and an account in the `docker` group (on the sites, the one that installed Fluxer). On the sites also: `jq`, `dig` (`bind9-dnsutils`), `chrony`, `iptables`, `openssh`.

```sh
apt install wireguard jq bind9-dnsutils chrony iptables sudo openssh-client openssh-server
```

**Check your install first.** fluxer-ha supports upstream's layout with the bundled Postgres, Valkey and SeaweedFS, and either TLS mode (`--tls bundled`, the default, or `--tls proxy`). It does **not** support `FLUXER_POSTGRES_URL`, an outside `FLUXER_KV_URL`, `external-object-store.compose.yml` or `tunnel.compose.yml`. `fluxer-ha doctor` checks this for you.

**`FLUXER_KV_URL` must not be set at all,** not even to the bundled Valkey: `init` writes its own, with the password HA adds, and refuses a `.env` that already has one. If yours says `FLUXER_KV_URL=redis://valkey:6379/0`, that's the stack's own default written out: comment the line out (`sed -i 's/^FLUXER_KV_URL=/#FLUXER_KV_URL=/' .env`). Nothing restarts, and a recreated container gets the same address from upstream's compose file. Any other value is an outside Valkey or Redis, which fluxer-ha can't replicate.

**Ports.** In your provider's firewall (and any host firewall):

| Port | Between | Why |
|---|---|---|
| UDP 51820 | all three hosts | WireGuard |
| TCP 80, TCP 443, UDP 443 | the internet → **both sites** | Your Fluxer domain. Site 2 serves it after a failover. |
| TCP 7881, UDP 7882 | the internet → both sites | LiveKit (voice) |
| TCP 22 over `wg0` | site 1 ↔ site 2 | The restricted SSH link (step 8). Docker-published ports bypass host firewalls, but `sshd` doesn't. So with ufw, for example: `ufw allow in on wg0 from <peer WireGuard IP> to any port 22 proto tcp`. |

Everything else the HA layer adds (Postgres, Patroni, etcd, Valkey, S3, the filer) listens on the WireGuard address only, behind fluxer-ha's own firewall. Don't open it anywhere.

**This repository, on all three hosts.** Clone it (or copy a release) to the same place on each, for example `~/fluxer-ha`:

```sh
git clone <fluxer-ha repository URL> ~/fluxer-ha
```

Until step 5 (step 6 on the witness), run it as `~/fluxer-ha/fluxer-ha`. `install` then puts a root-owned copy on your `PATH` as `fluxer-ha`. Later steps use that.

Keep the checkout **outside** the Fluxer directory: `install` creates `<Fluxer directory>/fluxer-ha/` for its own files, secrets and state, so a checkout there would be overwritten.

**Back up first:** `.env`, and a `pg_dump` of the database (`docker compose exec -T postgres pg_dump -U fluxer -d fluxer -Fc > fluxer.dump`).

## 1. WireGuard between the three hosts

Each host gets a WireGuard address; the examples use `10.77.0.1` (site 1), `10.77.0.2` (site 2) and `10.77.0.3` (witness). Every host lists the other two as peers.

Make each host's key pair, readable by root only:

```sh
sudo sh -c 'umask 077; wg genkey > /etc/wireguard/wg0.key; wg pubkey < /etc/wireguard/wg0.key'   # prints this host's public key
```

Example for site 1, `/etc/wireguard/wg0.conf` (root-owned, mode 600, and never written by any tool that takes outside input: `wg-quick` runs its `PostUp`/`PreDown` lines as root):

```ini
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = <site 1 private key: wg genkey>

[Peer]   # site 2
PublicKey = <site 2 public key>
Endpoint = <site 2 public IP>:51820
AllowedIPs = 10.77.0.2/32
PersistentKeepalive = 25

[Peer]   # witness
PublicKey = <witness public key>
Endpoint = <witness public IP>:51820
AllowedIPs = 10.77.0.3/32
PersistentKeepalive = 25
```

`AllowedIPs` must be a single `/32` per peer. WireGuard then accepts a packet from `10.77.0.3` only if it was encrypted with the witness's key. The firewall and the SSH `from=` rules rely on that.

`sudo systemctl enable --now wg-quick@wg0` on each host. Then `ping` every other host's WireGuard address from each host. fluxer-ha expects the interface to be `wg0` under `wg-quick`, unless you pass `--wg-interface` to `init`.

## 2. DNS

Your Fluxer name must already have an **A record pointing at site 1** (and an AAAA record, if you use IPv6). Lower its TTL to **60 s** a day ahead, so the change has spread before you need it.

| `--dns` | Set up |
|---|---|
| `cloudflare` | The record must be **DNS only** (grey cloud): fluxer-ha writes it with `proxied=false`, so a proxied (orange) record would quietly become DNS-only at the first failover. Create an API token with *Zone → DNS → Edit* for that one zone. You'll need the zone ID (on the zone's overview page) and the record ID (below). |
| `exec` | Write a hook for your DNS provider ([dns.md](dns.md)) |
| `none` | Something else moves traffic (a floating IP, a load balancer). The HA layer leaves DNS alone. |

**Finding the record ID without the token on screen.** Read the token without echoing it, and give it to curl on stdin, so it stays out of your history and the process list:

```sh
printf 'Token: '; read -rs TOKEN; echo
ZONE=<zone ID>
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s --config - \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?name=chat.example.com" | jq -r '.result[] | "\(.type) \(.id)"'
unset TOKEN
```

The `A` line's ID is `FLUXER_HA_CF_RECORD_ID_A` (and `AAAA`'s, if you have one, `_AAAA`). Once the token is in `fluxer-ha/.env.shared` (step 4), `TOKEN=$(sed -n 's/^FLUXER_HA_CF_API_TOKEN=//p' fluxer-ha/.env.shared)` reads it from there instead.

## 3. Check each host

On every host, from a checkout of this repo, as that account (not root):

```sh
./fluxer-ha doctor site      # on the sites, in or with --dir <your fluxer dir>
./fluxer-ha doctor witness   # on the witness
```

Fix every `FAIL` line. `doctor` changes nothing and needs nothing from the later steps: it comes **before** `init`, and `init` runs it again itself. Expected at this point:
- `FAIL  no WireGuard interface wg0` on any host where step 1 isn't done yet (an admin tunnel of yours on another interface doesn't count);
- on site 2, before step 7, "no Fluxer directory" as a warning.

On the witness it checks less: the account, Docker and Compose, the tools and `wg0`.

## 4. Site 1: write the settings

Run it from your Fluxer directory, or give that directory as `fluxer-ha --dir <dir> init …`: **`--dir` goes before the command**, never after it. Once `install` has run, fluxer-ha remembers the directory.

```sh
cd ~/fluxer     # the directory install.sh created
~/fluxer-ha/fluxer-ha init \
  --site1-wg 10.77.0.1 --site2-wg 10.77.0.2 --witness-wg 10.77.0.3 \
  --site1-ip <site 1 public IPv4> --site2-ip <site 2 public IPv4> \
  --dns cloudflare
```

More options for `init`:
- **`--domain <name>`:** the DNS record's name, if it isn't your `FLUXER_DOMAIN`. That's the name fluxer-ha updates and checks; the certificate is always for `FLUXER_DOMAIN`.
- **`--proxy-network <network>`** (with `--tls proxy`, when your reverse proxy runs in Docker, as in `--proxy-network caddy_default`): puts the edge on your proxy's Docker network through `fluxer-ha/ha.proxy-network.yml`. `docker network ls` shows the name; Compose calls it `<project>_default`. If you had edited upstream's `docker-compose.proxy.yml` for this, put upstream's file back. `install.sh --update` would overwrite it anyway.
- **Your own overlays:** any other file in your `COMPOSE_FILE` stays there, after upstream's files and before fluxer-ha's, and `bundle` takes it to site 2. It must sit in `~/fluxer` itself. If one of yours already puts the edge on your proxy's network, don't pass `--proxy-network` as well; `init` warns when both name the same network. (Lab: an overlay `edge-caddy-net.yml` was kept, bundled and flagged; one outside the directory, or missing, was refused.)
- **`--cert edge|caddy|none`:** where the certificate lives. The default is `edge` for bundled TLS and `caddy` for `--tls proxy`.
- **`--wg-interface <name>`:** if it isn't `wg0`.

### The settings files, and how they reach the other hosts

You don't write any of these files by hand. `init` writes them all from your current `.env`, and nothing your running stack reads changes:

| File | What | How it gets to its host |
|---|---|---|
| `fluxer-ha/.env.shared` | Your `.env` without the per-site keys, plus the HA settings and six new secrets. **Must be byte-identical on both sites.** | In the site 2 bundle (below) |
| `fluxer-ha/.env.site` | Site 1's own values (its addresses, snowflake worker ID, ...) | Stays on site 1 |
| `fluxer-ha/init/site2.env.site` | Site 2's own values | In the site 2 bundle, where it becomes site 2's `.env.site` |
| `fluxer-ha/init/witness.env` | The witness's address and the etcd member list (no secrets) | You copy it (step 6) |

Each site later builds its own `.env` from its `.env.shared` and `.env.site` (`fluxer-ha/build-env.sh`, run for you by `migrate`, `etcd-up` and `join`). **After the install,** a change to `.env.shared` is made on one site and copied byte for byte to the other. Then run `fluxer-ha/build-env.sh` and `fluxer-ha rollout` on each ([operations.md](operations.md#upgrades)). Nothing copies it for you. The SSH link between the sites can only compare it, and the spare's health check fails while the two copies differ.

### Edit `fluxer-ha/.env.shared` (on site 1, before the bundle)

| Setting | Set it to |
|---|---|
| `FLUXER_HA_CF_API_TOKEN`, `FLUXER_HA_CF_ZONE_ID`, `FLUXER_HA_CF_RECORD_ID_A` (and `_AAAA`) | With `--dns cloudflare`: the token and IDs from step 2 |
| `FLUXER_HA_DNS_HOOK` | With `--dns exec`: the path of your hook ([dns.md](dns.md)) |
| `FLUXER_HA_HEARTBEAT_URL` | A dead-man's-switch URL that alerts when pings **stop**, from healthchecks.io, Uptime Kuma's push monitor or any equivalent. Set it to alert after **2 minutes** without a ping. |
| `FLUXER_HA_ALERT_URL` | A URL that receives a POST for each event, such as an ntfy topic |
| `FLUXER_HA_CADDY_DATA_VOLUME`, `FLUXER_HA_CADDY_CONTAINER` | With `--cert caddy`: your Caddy's data volume (the one mounted at `/data`, as in `caddy_caddy_data`) and its container name (as in `caddy-caddy-1`, or what `container_name:` sets). `docker inspect <container> --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{println}}{{end}}'` lists the volumes. **Both are shared settings, so they must be the same names on both sites.** |
| `FLUXER_HA_FAILBACK_STABLE_SECONDS`, `FLUXER_HA_FAILBACK_HOURS`, `FLUXER_HA_FAILBACK_ENABLED` | Optional: how long site 1 must be healthy before the primary moves back to it (default 1 h), a time window for that, or off |

**The heartbeat and alert URLs are optional for the install** (without them, events only reach the logs), but set them now if you can. Before `bundle` it's an edit; after `join` it's a configuration change with a rollout. [operations.md](operations.md#monitoring) says what to point them at, Uptime Kuma included.

With `--tls proxy`, also follow [reverse-proxies.md](reverse-proxies.md) for your proxy's site block. The `abort` on 502 matters.

Then pack site 2's files from the edited settings:

```sh
~/fluxer-ha/fluxer-ha bundle
```

It writes `fluxer-ha/init/site2-bundle.tar.gz`: the stack files, `fluxer-ha/.env.shared` and site 2's `fluxer-ha/.env.site`. Run it again if you edit `.env.shared` before site 2 has joined, and copy the new one.

## 5. Install the files (site 1)

```sh
cd ~/fluxer && ~/fluxer-ha/fluxer-ha install site
```

This puts the scripts, the overlays and the state directory in `~/fluxer/fluxer-ha/` (owned by you), and the systemd units in place, **without enabling them**. It asks `sudo` for its `[root]` steps:
- the units, rendered to run as you;
- a root-owned copy of `fluxer-ha` in `/usr/local/share/fluxer-ha`, linked from `/usr/local/bin/fluxer-ha`, so `fluxer-ha` works from any directory (it finds `~/fluxer` itself once installed; before that, run it from there or pass `--dir`);
- `softdog`, if there's no watchdog, and the watchdog device handed to uid 999 (Postgres in the Patroni image).

Running it again later updates the site in place ([operations.md](operations.md#upgrading-fluxer-ha-itself)).

## 6. The witness

Copy `witness.env` from site 1 to the witness, for example from your workstation:

```sh
scp site1:fluxer/fluxer-ha/init/witness.env witness:
```

Then, on the witness:

```sh
~/fluxer-ha/fluxer-ha install witness                  # files in ~/fluxer-witness
install -m 600 ~/witness.env ~/fluxer-witness/.env && rm ~/witness.env
fluxer-ha witness-up
```

`install witness` also puts the firewall in place, and `witness-up` enables it (both through `sudo`). It lets only the two sites reach the witness's etcd, and only over WireGuard.

## 7. Site 2: unpack and install

**With `--tls proxy`, set up your reverse proxy on site 2 first.** It's the same as on site 1:
- the same Fluxer site block (or snippet), with the `abort` from [reverse-proxies.md](reverse-proxies.md);
- for a Caddy in Docker, the **same** network, data volume and container names as on site 1, because `.env.shared` names them for both sites.

Start it. Until site 2 is primary, it answers your other sites and closes connections for the Fluxer domain. Its certificate for the domain comes from site 1 after `join` (step 11).

Copy `fluxer-ha/init/site2-bundle.tar.gz` to site 2. It holds every secret your instance has, so use `scp`, for example from your workstation (`-3` copies through it, so the sites need no SSH access to each other):

```sh
scp -3 site1:fluxer/fluxer-ha/init/site2-bundle.tar.gz site2:
```

Unpack it into site 2's Fluxer directory. The same path as on site 1 keeps every command the same on both sites, but it may differ.

On site 2:

```sh
mkdir -p ~/fluxer && tar -xzf ~/site2-bundle.tar.gz -C ~/fluxer   # or another directory: then use it below && chmod 600 ~/fluxer/fluxer-ha/.env.*
cd ~/fluxer && ~/fluxer-ha/fluxer-ha doctor site       # now checks the unpacked files too
~/fluxer-ha/fluxer-ha install site
rm ~/site2-bundle.tar.gz
```

Delete site 1's copy too, once site 2 has joined (step 13).

## 8. The restricted SSH link (both sites)

The sites use SSH for two things only: comparing `.env.shared`, and copying the TLS certificate to the spare. Each one only accepts those two commands from the other ([security.md](security.md)).

```sh
site1$ fluxer-ha ssh-link                       # prints site 1's key
site2$ fluxer-ha ssh-link --peer-key '<site 1 key>'   # prints site 2's key
site1$ fluxer-ha ssh-link --peer-key '<site 2 key>'
```

Pass the **whole printed line** (`ssh-ed25519 AAAA… fluxer-ha@<host>`) in single quotes, or in double quotes around a variable (`read -r K`, then `--peer-key "$K"`). It must be one line. It's a public key, so it's no secret: on its own it opens nothing, and the peer's copy accepts it only from your WireGuard address and only for the two commands.

How it works: `ssh-link` creates an unprivileged `fluxer-ha` account (not in the `docker` group) whose `authorized_keys` (root-owned) has the peer's key with `restrict`, `from="<peer WireGuard IP>"` and a forced command, `/usr/local/lib/fluxer-ha/ssh-gate.sh`. The gate runs one of two verbs and nothing else: `env-hash` (a hash of `.env.shared` and the image lock, for the drift check) and `cert-receive` (a certificate for the spare; refused on the primary). It runs them as you through a sudo rule that allows exactly those two. [security.md](security.md) has the hardening (S16, S17, S24) and what the lab threw at it.

## 9. Start site 2's etcd member

```sh
site2$ fluxer-ha etcd-up
```

Run it on **site 2 only**; it refuses on site 1. Each etcd member is started by a different step:

| Member | Started by |
|---|---|
| witness | `witness-up` (step 6) |
| site 2 | `etcd-up` (this step) |
| site 1 | `migrate` (step 10), during its cut-over |

All three must be running before Patroni starts for the first time: a new cluster with a member that has never started reports an old cluster version, and Patroni then waits forever ([lab-results.md](lab-results.md) F34). So before it changes anything, `migrate` checks that the witness's and site 2's members are running, and stops with "etcd at … isn't running" if either isn't. It then starts site 1's own member itself.

## 10. Migrate site 1 (the maintenance window)

```sh
site1$ fluxer-ha migrate
```

**This is the first step that needs the witness.** Everything before it (steps 0–5 and 7–9) works with the witness still off or not set up, and your instance keeps running as before. `migrate` refuses, changing nothing, until the witness's etcd answers (step 6).

1. **Before the window:**
   - checks everything again, including that the witness is reachable;
   - builds the Patroni image and pulls the HA images.
2. **The window starts:**
   - stops everything except Postgres;
   - dumps the database to `~/fluxer/fluxer-ha/backups/` (upstream's `install.sh --update` keeps its records in `~/fluxer/backups/`).
3. **The cut-over:**
   - switches to the HA settings;
   - starts etcd and turns on its authentication;
   - turns on the firewall;
   - starts Patroni on a **new** volume;
   - restores the dump and checks the row count.
4. **The window ends:** the warm tier is recreated with the HA settings, then the controller starts the rest of the app tier. The window closes once your instance answers on HTTPS.

If anything fails before the restore checks out, `migrate` **rolls back by itself**: it restores your old `.env` and starts the old stack. Your old database volume (`fluxer_postgres-data`) is never touched; keep it, with the dump and `fluxer-ha/.env.pre-ha` (your single-site `.env`), until the drills pass.

## 11. Join site 2

```sh
site2$ fluxer-ha join
```

1. Pulls the images and builds Patroni.
2. Starts etcd (all three members healthy) and the firewall.
3. Starts the data tier. Patroni clones the database from site 1, and `join` waits until site 2 is the **synchronous standby**.
4. Starts the warm tier.
5. Creates the app tier **without starting it**, and enables the timers.

Within about 2 minutes, site 1 copies its TLS certificate to site 2 (`fluxer-ha-certs.timer`, hourly after that). Until that copy is there, valid and trusted, site 2's health check fails with a certificate message. That's on purpose: a failover before then would serve a bad certificate (lab F40).

It also fails with `s3-mirror unhealthy` until site 2's first full media copy from site 1 is done: failback never moves onto incomplete media. A small instance takes seconds (lab, 2026-10-17: about 50 s after `join`), and a large one about 7 minutes per GB at 20 Mbit/s ([operations.md](operations.md#s3-mirror-stops-or-skips-objects)).

## 12. Check, then drill

```sh
fluxer-ha status    # on both sites
```

You want:
- site 1 `Leader`, site 2 `Sync Standby` with lag 0;
- all three etcd members healthy;
- on site 2, `ha-health OK`, and your heartbeat monitor receiving pings;
- an alert arriving at `FLUXER_HA_ALERT_URL`: the role changes during the first drill send some.

Then run the drills in [testing.md](testing.md), at a quiet time, **before** you rely on any of this. With `--tls proxy`, run `gd-proxy-fence.sh` on both sites too.

## 13. Clean up

`migrate` kept everything needed to roll back. Once the drills pass, delete it. Each item holds every secret or every row:

```sh
site1$ cd ~/fluxer && rm fluxer-ha/.env.pre-ha fluxer-ha/init/site2-bundle.tar.gz
site1$ rm ~/fluxer/fluxer-ha/backups/pre-ha-*.dump     # or move it to your off-site backups
site1$ docker volume rm fluxer_postgres-data           # the pre-HA database; nothing uses it now
```

Keep backing up as before: replication copies deletes and corruption too ([security.md](security.md#not-covered)).

**From here on:** upgrades, settings changes and pinning images by digest are in [operations.md](operations.md#upgrades).
