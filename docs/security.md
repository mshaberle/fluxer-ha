# Security

## Threat model

**Public:** only your edge or proxy (80/443), LiveKit, and WireGuard (UDP 51820) are reachable from the internet. Everything the HA layer adds listens on the **WireGuard** addresses only.

Both sites hold every secret, so a compromised site is a compromised instance, whatever this layer does. The questions that matter are about the rest:
- a compromised **witness** (small, cheap, often less maintained);
- a compromised **container** on a site, for example through a bug in a service that fetches URLs;
- an unprivileged **local user** on a site.

## Controls

| # | Risk | Control | Lab re-test |
|---|---|---|---|
| S1a | Patroni's REST API can change Postgres settings, restart, fail over, re-clone | Basic auth on every state-changing method (`PATRONI_RESTAPI_USERNAME/PASSWORD`); GETs such as `/primary` stay open for health checks | A container's `POST /restart`, `PATCH /config` and a local user's `POST /switchover` got **401** |
| S1b | etcd holds Patroni's state; a writer can steer it | etcd RBAC ([etcd-auth.sh](../lib/etcd-auth.sh)): user `patroni` with read/write on `/fluxer/` only; `root` only inside the sites' etcd containers | Reads and writes without a user, and a guessed root password, were **refused**, from the witness, a container and a local user |
| S1c | `pg_hba` open to the whole mesh would let the witness in | A /32 for each site only ([entrypoint.py](../patroni/entrypoint.py)) | The witness as `postgres` or `replicator`: **"no pg_hba.conf entry"** |
| S2 | Valkey without a password: sessions, caches, `REPLICAOF` an attacker | `requirepass` and `masterauth`, given to Valkey on stdin (never in `ps`); `FLUXER_KV_URL` carries it; a healthcheck that requires `PONG`, because `valkey-cli ping` exits 0 on `NOAUTH` | A container's `PING`: **NOAUTH**. Replication with auth: up. No password in any argv. |
| S3 | The SeaweedFS filer reads and writes every object without credentials | Reachable over WireGuard **from the peer site only** (S5). The filer's JWT covers HTTP only, and its gRPC port would need mutual TLS across all of SeaweedFS, which would change upstream's setup, so the firewall is the boundary. | The witness: **blocked**. (A container on the same site can still reach it, as in upstream's single-site stack.) |
| S4 | SQL injection through Patroni's `/history` (mirrored from etcd) into a superuser query | A strict ISO-8601 check, then a psql variable | The payload is rejected |
| S5 | Host firewalls don't see Docker-published ports | Rules in `DOCKER-USER` ([firewall.sh](../lib/firewall.sh)): the peer gets the HA ports, the witness only etcd 2379/2380, anyone else nothing. Applied at boot, re-checked every 30 s, swapped in atomically. | The witness reached 2379/2380 only |
| S6 | Tokens on curl's command line are visible in `/proc` | The DNS token, alert and heartbeat URLs and the Patroni password reach curl on stdin (`--config -`) | DNS updates worked in every drill |
| S7 | A compromised primary could keep restarting the spare's Caddy (and your other sites) by sending new certificates | At most one restart per hour; the rest wait | Two certificates 3 s apart: one restart, one deferred |
| S8 | Drill evidence readable by everyone | `fluxer-ha/state/evidence`, umask 077 | — |
| S9 | Tags can move under you | Patroni's base image by digest, its Python packages by sha256 (`--require-hashes`), the HA layer's own images by digest; optional `ha.images.lock.yml` for every service | Built with `--require-hashes`; the lock pinned 29 services |
| S14 | **A LAN neighbour bypassed WireGuard.** Linux accepts a packet for any local address on any interface, and Docker's DNAT for a port published on the WireGuard address matches every interface. A host on the provider's LAN that routed `10.77.0.0/24` at a site reached **every** HA port, including the filer, which listed all buckets without credentials, and etcd's peer port, which has no auth at all. The witness's etcd was open in the same way, and the witness had no firewall. | Every packet Docker forwards now passes the chain. Anything addressed to the WireGuard address that didn't arrive over WireGuard is dropped (this host's own Docker bridges excepted). **The witness runs the same firewall**, allowing only the two sites' etcd traffic. | Before the fix, from the Proxmox host on the lab's LAN: 2379, 2380, 5432, 6379, 8008, 8333, 8888 and 18888 all open, and the filer listing returned. After it: every one filtered, on both sites and the witness. |
| S15 | Root wrote into the user-owned state directory: the firewall check wrote `firewall.status.tmp` there, then chmod'ed it, so a planted symlink would redirect both. It also sent its alert to a URL from `.env` without checking it. | First fixed by moving the status to a root-owned `/run/fluxer-ha`. **Superseded by S21:** the firewall no longer runs as root, so it writes into its own account's directory. The alert URL must still be a plain `http(s)` URL (`--proto =http,https`). | Every unit runs as the Fluxer user; the status is written by that user |
| S16 | `cert-receive` checked the peer's archive with the host's GNU tar but unpacked it with busybox tar in a container, so a crafted archive that the two parse differently could slip past the path check. The refused-command log line also took raw input from the peer, newlines included. | GNU tar unpacks the archive into a private directory, the files that landed there are checked, and only a fresh archive of that tree reaches the container (key files mode 600). The log line is cut to printable characters. | Symlink, `../`, absolute path, hard link, FIFO, an unexpected file, another domain, a pax path override and garbage were all refused; a real certificate installed |
| S17 | `ssh-link --peer-key` checked the key with `grep`, which matches line by line. A two-line value would add a second key **without** `restrict`, `from=` or the forced command, giving that key a shell as `fluxer-ha` (the operator has to paste it). | Exactly one line, an `ssh-ed25519` key and a plain comment. `authorized_keys` is root-owned (644), so the account can't change its own keys. | A two-line `--peer-key` was refused and `authorized_keys` kept one line |
| S18 | Under Debian's umask 002, `fluxer-ha/` and its subdirectories were group-writable, as was the peer's `known_hosts` | `install` sets them to 755 and `known_hosts` to 644 | Nothing group- or world-writable under `fluxer-ha/` or the state directory |
| S20 | The containers the HA layer adds (etcd, `valkey-role-link`, `filer-sync`, `s3-mirror`) ran as root with Docker's default capabilities (`NET_RAW`, `CHOWN`, `DAC_OVERRIDE`, `SETUID`, …) and a writable root filesystem, and Patroni kept the default capabilities. None of them needs any. | `cap_drop: [ALL]` and `no-new-privileges` on all five; a read-only root filesystem with a private `/tmp` on the four; `nobody` for the two loops that write nothing persistent. Patroni already runs as `postgres`. | All healthy after a rolling `rollout`. Valkey replication up, a file copied by the `nobody` `filer-sync` in 2 s, `CapEff` 0 and `NoNewPrivs` 1 in Patroni. |
| S21 | **Root at run time:** the firewall units ran as root, though `iptables` needs only `CAP_NET_ADMIN`. No unit was sandboxed (`systemd-analyze security`: 9.2–9.6, "UNSAFE"). | The firewall runs as the Fluxer user with only `CAP_NET_ADMIN`. Every unit gets `NoNewPrivileges`, an empty capability set and systemd sandboxing. Fresh installs skip the old-version probes of `/root`. | No fluxer-ha unit runs as root; exposure 3.3 and 3.6, "OK"; every drill passed with the sandbox on |
| S22 | **Supply chain, brought up to date:** etcd 3.5.17 → **3.6.15**, alpine 3.20 → **3.24**, rclone 1.68.2 → **1.75.2**, Patroni 4.0.4 → **4.1.5** (all by digest or sha256). The Postgres 16 base was already current. etcd's 3.6.9 and 3.5.28 releases fixed CVEs by requiring authentication for cluster-topology reads and lease keepalives, which **Patroni before 4.1.1 can't handle**. | New pins in `compose/`, `witness/` and `patroni/`. `requirements.txt` was regenerated: Patroni 4.1 added `py-consul` (and `requests`) and `ydiff` as hard dependencies. On an existing pair, roll out Patroni 4.1 **before** etcd ([operations.md](operations.md#upgrades)). | A fresh install, the drills and the audit all ran on the new versions |
| S23 | The Patroni image carried `gosu`, built with an old Go (25 high and 1 critical fixable findings), and `setuptools` 66.1.1 (2 high), and used neither at run time | Both are removed after the build. A scan with Trivy 0.76 now finds **0** fixable high or critical vulnerabilities in the Patroni image, rclone and alpine. etcd 3.6.15 has 12 high in its Go dependencies, and there's no newer etcd yet. | Built, rolled out, drilled |
| S24 | **The SSH account owned the watchdog.** `useradd --system` took the first free system uid, 999 on Debian's cloud image. That's Postgres's uid inside the Patroni image, which the udev rule hands `/dev/watchdog` to. The account could only run the gate, but had that ever failed, it could have held the watchdog open and reset the host at will. | `ssh-link` creates the account with a free system uid that's never 999, and moves an existing account off 999. `doctor` warns when any host account has uid 999. | Found in the softdog test (`ls -l /dev/watchdog` showed `fluxer-ha`) |

The restricted SSH link between the sites was attacked in the lab, and it held. It refused arbitrary commands, command injection, extra arguments, a shell, port forwarding, and the key from any address other than the peer's WireGuard address. `env-hash` reports what the peer **says**, so it catches mistakes, not attacks.

**Live audit (2026-10-16, a pair installed from scratch as the installing user): 148 checks, 0 failures** after the fixes above. Repeated on fresh installs since: 268 checks on 2026-10-17 (eighth run: one real finding, H2, fixed; ninth run: all passed), with the same results below ([lab-results.md](lab-results.md#security-audits)).
- **Exposure:** from a LAN neighbour not in WireGuard, only 22, 80, 443 and LiveKit answer on the primary's LAN address, only 22 on the spare and the witness, and nothing on any WireGuard address.
- **The witness's reach:** it reaches only etcd on the sites.
- **No credentials, no access:** without credentials, etcd, Patroni's unsafe methods, Valkey and Postgres all refuse.
- **The SSH gate:** it refused every command variant, an interactive login, every kind of forwarding, its key from the LAN address, and every crafted archive.
- **sudo:** the `fluxer-ha` account can't reach root or a shell.
- **Secrets:** none of 22 secret values appeared in any argv, journal, state log or container log.
- **Files:** everything root runs is root-owned all the way up the path.

**Host hardening, yours to do** (seen on Debian's cloud image):
- turn off LLMNR (`systemd-resolved` answers on 5355 on every interface);
- set `PermitRootLogin no` unless you log in as root.

## The witness is inside the trust boundary

The witness is an etcd **member**. It takes part in Raft and holds the whole etcd database on disk, so **a compromised witness can write anything Patroni reads from etcd, passwords or not**.

Patroni lets local settings override etcd's for most keys, but not all. In Patroni 4.0.4, `standby_cluster`, including its `restore_command`, comes only from etcd ([patroni/config.py](https://github.com/patroni/patroni/blob/v4.0.4/patroni/config.py), `_build_effective_configuration`; read in the lab, and not re-checked for 4.1.5, the version pinned now). So a compromised witness can make Patroni run a command. Auth and the firewall stop it from reaching Postgres, Valkey, the filer and Patroni's API **directly**, but not from steering Patroni.

So treat the witness like a site:
- WireGuard and the one etcd container, nothing else listening.
- SSH by key only, from a short list of addresses, and automatic security updates.
- Two-factor authentication on the provider account: whoever controls its console controls the witness.

## Secrets

- **Where they live:** every secret is in `.env.shared` / `.env.site` and the generated `.env`. The files are owned by the account that installed Fluxer, mode 600, and identical on both sites. `init` generates the six new ones with `openssl rand -hex 32`.
- **How the scripts read them:** with `sed`, never by sourcing the file, and they never print them.
- **The site 2 bundle** holds them all. Copy it with `scp`, then delete both copies (`fluxer-ha/init/site2-bundle.tar.gz` on site 1 included).
- **Left behind by `migrate`:** `fluxer-ha/.env.pre-ha`, the dump in `fluxer-ha/backups/` (mode 700) and the old `postgres-data` volume, each holding every secret or every row. Delete them once the drills pass.
- **Rotating one** is a configuration change ([operations.md](operations.md#upgrades)). For the etcd passwords, run `fluxer-ha/etcd-auth.sh users` after changing them, and before the rollout.

## What runs as root

Like upstream's installer, `fluxer-ha` runs as **the account that installed Fluxer** (in the `docker` group). It refuses root unless you pass `--allow-root`; with that flag, everything below runs as root instead.

**At run time, nothing runs as root.** Every unit has `User=` set to that account. Each item below was re-audited for whether it truly needs root (2026-10-16, lab):

| What | Needs root? | Runs as | Evidence and reason |
|---|---|---|---|
| **The firewall** (`fluxer-ha-firewall.service` at boot, `fluxer-ha-firewall-check.timer` every 30 s; sites and witness) | **No: only `CAP_NET_ADMIN`** | you, with that one capability | The lab created, changed and deleted an `iptables` chain as the user with only `CAP_NET_ADMIN`. The units grant it as an ambient capability, with the bounding set limited to it and `NoNewPrivileges`. The code that holds the capability is a root-owned copy (`/usr/local/lib/fluxer-ha/firewall.sh`) that your account can't edit. |
| **Controller, health, failback, certificate copy** | No | you, **no capabilities** | Docker, curl, files in `~/fluxer` (their state in `~/fluxer/fluxer-ha/state`) |
| **The SSH gate** | No | `fluxer-ha` (unprivileged), then you through `sudo -u` | The sudo rule allows only the gate's two verbs, as you, never as root. Its own account is defence in depth: if `restrict` or the forced command ever failed, a peer would land in an account with no Docker access. |
| **Day-to-day commands** (`status`, `switchover`, `hold`, `release`, `rollout`, `pin`, `upgrade-fetch`, `doctor`, `init`, `bundle`, `witness-up`) | No | you | |
| **`install`** | **Yes** | root through `sudo`, each step printed with `[root]` | It writes system locations: `/etc/systemd/system` (the units and the Docker-after-WireGuard drop-in), `/etc/fluxer-ha`, `/etc/udev/rules.d` (the watchdog for uid 999), `/etc/modules-load.d` (`softdog`), `/usr/local`. The state directory, `~/fluxer/fluxer-ha/state`, it creates as you, without root; an older install's `/var/lib/fluxer-ha` it moves there (the one root step for it). On a fresh host it no longer probes `/root/.ssh` for an old install's key; it does that only when an older config is found. |
| **`ssh-link`** | **Yes** | root through `sudo` | A system account, `/etc/sudoers.d`, and that account's root-owned `authorized_keys` |
| **`migrate`, `join`, `etcd-up`, `witness-up`** | Only for `systemctl enable --now` | root through `sudo` for that one step | The rest is yours. |
| **`gd-site-link-cut.sh`, `gd-link-latency.sh`** | Only `CAP_NET_ADMIN` | `sudo` | They change `iptables` and `tc`. sudo is how a drill gets the capability. |
| **`gd-kill-service.sh`** | **Yes** | `sudo` | It simulates a crash with SIGKILL to a container's main process from the host. `docker kill` can't stand in for it: the lab showed Docker treats it as a manual stop and **skips the restart policy**; the killed container stayed exited until the controller's 30-second check started it. |
| **Postgres and Patroni** | No | `postgres` (uid 999) inside the container, **no capabilities** | |
| **The HA layer's other containers** (S20) | No | etcd and `s3-mirror` as the image's root but with **no capabilities**; `valkey-role-link` and `filer-sync` as `nobody`. All four have a read-only root filesystem and no privilege escalation. | `filer-sync` copied a test file from site 1's filer to site 2's in 2 s while running as `nobody`. |

**Sandboxing.** The units now carry systemd sandboxing:
- `NoNewPrivileges`, so nothing a unit runs can regain privileges, even through sudo;
- no capabilities (the firewall keeps only `CAP_NET_ADMIN`);
- `ProtectSystem=full` (`/usr` and `/etc` read-only);
- a private `/tmp` and private devices;
- no kernel tunables, modules or logs;
- restricted address families, no namespaces, native system calls only.

`systemd-analyze security` scores them **3.3** (the four services) and **3.6** (the firewall), "OK", down from **9.2–9.6, "UNSAFE"**. Hooks and the DNS `exec` hook run inside the same sandbox.

**What this does and doesn't buy.** The `docker` group is root-equivalent: Docker documents that a member can start a container with the host's root filesystem mounted, and these services need the Docker socket. So a compromised service can still get root **through Docker**. What the changes buy:
- **No direct root:** nothing of fluxer-ha holds root, or any capability beyond `CAP_NET_ADMIN`, when it runs.
- **Contained mistakes:** a bug can't write `/usr` or `/etc`, load a kernel module or change the clock.
- **One owner:** files have one owner, so `docker compose` and upstream's installer keep working.
- **No routine `sudo`:** day-to-day commands don't need it, as with upstream.

Taking Docker access away isn't possible, because starting and stopping containers is the services' job. **Rootless Docker doesn't work with this design as it stands** (tested 2026-10-16 on a separate Debian 13 VM, Docker 29.9.1 rootless with its default port driver):
- **The firewall protects nothing.** A `DROP` in the host's `DOCKER-USER` chain matched 0 packets, and the published port still answered. Rootless ports are a `rootlesskit` process listening on the host, so only the host's `INPUT` chain applies (a `DROP` there did block). The firewall would need rewriting for `INPUT`.
- **Postgres can't tell clients apart.** Every connection reached the container from `172.17.0.1`, from the host and from another machine alike, as Docker's documentation says for the default port driver. Patroni's `pg_hba` rules allow replication only from the peer site's address; under rootless, they'd allow everyone or no one.
- **No watchdog.** Inside the container, `/dev/watchdog` showed as owned by 65534 and couldn't be opened, as container root or as uid 999. Container uid 999 is host uid 100998 there, not the 999 the udev rule hands the device to. Without it, Patroni's `watchdog: required` refuses to lead.
- **Publishing on the WireGuard address itself works** (`-p 10.99.0.1:8432:80`).

**Keep the root-owned copies root-owned:** `/usr/local/lib/fluxer-ha`, `/usr/local/share/fluxer-ha` and `/usr/local/bin/fluxer-ha`. `install` creates them that way: writable by root only, readable by everyone, since they hold nothing but this repository's files (lab, ninth run: at mode 750 the installing user couldn't run the drills or the command on its `PATH`). They're what the firewall's capability and the gate's sudo rule apply to.

## Not covered

- **Sandboxing against Docker itself:** the units are sandboxed (above), but they need the Docker socket, and with it everything Docker can do.
- **TLS:** traffic between the sites isn't TLS-encrypted inside WireGuard, which already encrypts and authenticates it.
- **Backups:** replication copies deletes and corruption too. Keep a nightly `pg_dump` and a copy of the media buckets off both sites.
