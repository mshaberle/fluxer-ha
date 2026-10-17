# Testing your setup (game days)

Don't trust the failover until you've seen it work on **your** hosts. The scripts in [tests/](../tests) inject one fault each and revert it when they exit, including on Ctrl-C.

## Rules

- **Pick a quiet time.** These drills cause real, short outages; tell your users.
- **Measure from outside both sites.** Run `probe.mjs` on your laptop, or the witness, for the whole drill:

  ```sh
  FLUXER_URL=https://chat.example.com PROBE_TOKEN="Bot <token>" PROBE_CHANNEL_ID=<channel> \
  UPLOAD_EVERY_MS=10000 node tests/probe.mjs
  ```

  Use a bot or a test user in a **test guild**, never a real channel. A user's token works too (`PROBE_TOKEN=<token>`, no `Bot `): Fluxer refuses a user's messages until it has a gateway session (`MUST_START_SESSION_BEFORE_SENDING`), so the probe opens its session first and only then starts writing. Node 22+, no dependencies. Without Node 22 on the host, its official image does it: `docker run --rm --network host -v "$PWD/tests:/w" -w /w -e FLUXER_URL=... node:22-alpine node probe.mjs`. With a private CA, add `-e NODE_EXTRA_CA_CERTS=/w/ca.pem` rather than turning certificate checks off.
- **Every 10 s an upload of two files,** one text and one binary with random bytes. The probe logs each file's SHA-256 and size.
- **Analyse afterwards:** `node tests/analyze.mjs --inject <INJECT_AT> --verify --profile <profile> probe-<run>.jsonl`. With `--verify` it reads every message back (no acknowledged message lost, no duplicates, IDs in order), downloads every acknowledged attachment and **compares its bytes with what was sent**. The profile sets the time limits: `no-impact`, `service`, `planned` or `unplanned`.
- **Typed confirmation.** Every drill refuses to run without `HA_GAMEDAY=1`, then asks you to type the scenario name.
- **Who runs them.** As the account that installed Fluxer, except three that need `sudo` and say so: `gd-site-link-cut.sh` and `gd-link-latency.sh` change the network (iptables, tc), and `gd-kill-service.sh` signals a container's process from the host.

## The drills

| Script (in `fluxer-ha/tests/`) | Where | Expected |
|---|---|---|
| `gd-kill-service.sh api` | primary | The controller restarts it within seconds; no failover |
| `gd-witness-outage.sh 120` | witness | No impact. The heartbeat stops (no automatic failover is possible), then recovers. |
| `gd-site-link-cut.sh 120` | either site | No failover. Commits stall while the primary waits for the spare to time out (lab: 13 s for a database client; a real Fluxer client's sends failed for 19 s, its own 5 s timeouts included), then the spare is async until the link returns. |
| `gd-replica-outage.sh 120` | spare | No impact on users |
| `gd-link-latency.sh 3 120` | either | Writes a little slower; nothing else |
| `gd-mirror-pause.sh 120` | spare | Media catches up afterwards |
| `gd-switchover.sh` | primary | About 20–35 s of disruption on the user path; 0 lost |
| `gd-proxy-fence.sh [other sites]` | both sites, before and after a switchover (`--tls proxy` only; injects nothing) | Primary: the Fluxer domain answers 200 through your proxy with a trusted certificate. Spare: no edge, and the proxy **closes** the connection instead of answering 502, over HTTP/1.1 and HTTP/2. Both: the certificate hasn't passed its renewal point (a third of its lifetime left), and your other sites answer. |
| `gd-failback.sh` | preferred site, while primary | It switches away, then failback brings it back after the window. Set `FLUXER_HA_FAILBACK_STABLE_SECONDS=600` while drilling, then restore it. |

The unplanned failures are worth doing too, by hand:
- **Power the primary off** from your provider's console.
- **Freeze Patroni:** `sudo kill -STOP` on Patroni's **child** process: `pgrep -P $(docker inspect -f '{{.State.Pid}}' fluxer-postgres-1) -f /opt/patroni/bin/patroni`. As a container's PID 1, Patroni forks, and only the child runs the loop that renews the lease and keeps the watchdog alive; freezing the parent does nothing (lab). The watchdog should reset the host: in the lab, 22–26 s later with `softdog`.
- **Isolate the primary:** drop its WireGuard UDP.

Expect writes back within about 40 s and **0 acknowledged writes lost**. [lab-results.md](lab-results.md) has the lab's numbers to compare against.

**With a private CA** (a lab, `local_certs`), give both edges the same CA (copy `caddy/pki` from site 1's `edge-data` volume to site 2's) and make both sites trust its `root.crt` (`/usr/local/share/ca-certificates/`, then `update-ca-certificates`). Failback checks that the site serves HTTPS with a valid certificate, and otherwise it rolls itself back and backs off for 6 hours. `fluxer-ha release` clears the back-off.

After any drill: `HA_GAMEDAY=1 fluxer-ha/tests/gd-collect.sh "<start time>"` on each site saves the cluster state and logs to `fluxer-ha/state/evidence/`.
