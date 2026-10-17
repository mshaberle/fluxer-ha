# DNS failover

When a site becomes the Patroni primary, its controller runs `fluxer-ha/dns-failover.sh` in the background, and again every 10 minutes. It points the record at that site's `FLUXER_HA_PUBLIC_IPV4` (and `_IPV6` if set), retrying with back-off until it succeeds or the site stops being primary. Only the primary ever runs it, so the two sites never fight over the record.

The provider is `FLUXER_HA_DNS_PROVIDER`:

| Provider | What it does | Status |
|---|---|---|
| `cloudflare` | `PATCH`es the A/AAAA record by ID, with `proxied=false` and `FLUXER_HA_DNS_TTL`. The token goes to curl on stdin, never in argv. | Tested in the lab with a real zone |
| `exec` | Runs your program: `<FLUXER_HA_DNS_HOOK> <name> <A\|AAAA> <ip> <ttl>`. Exit 0 once the record holds `<ip>`. | Tested in the lab (2026-10-16) with a hook that PATCHes the same Cloudflare record: run by the controller, as the user, inside its sandbox, at a switchover, a failback and a hard power-off. A hook in a group-writable file or directory was refused. Your hook is yours to test. |
| `none` | Leaves DNS alone, for a floating IP or a load balancer health-checking `/_health` on both sites. The DNS health checks are skipped. | — |

## Writing an `exec` hook

- **Owned by root or by the account the services run as, and neither it nor its directory group- or world-writable.** `dns-failover.sh` refuses it otherwise, and alerts "not configured". `~/fluxer/fluxer-ha/hooks/` is made for it: yours, mode 755, and moved along by `install` from older layouts. It runs as that account (root only with `--allow-root`).
- **Safe to run again.** It's retried until it succeeds, and re-run every 10 minutes.
- **Secrets from a file** the hook reads (mode 600), never from its arguments.
- **Exit 0 only once the provider has accepted the change.**

Example skeleton:

```sh
#!/bin/sh
# ~/fluxer/fluxer-ha/hooks/dns-hook   (yours, 0755; it runs as you)
# FLUXER_HA_DNS_HOOK=/home/<you>/fluxer/fluxer-ha/hooks/dns-hook  (absolute)
set -eu
name=$1 type=$2 ip=$3 ttl=$4
. "$(dirname "$0")/dns-hook.secret"   # TOKEN=...   (yours, 0600)
# Call your provider's API here. Pass the token through a config file or
# stdin rather than argv, for example: curl --config - <<EOF ... EOF
```

## TTL

Users stay on the old address for up to the TTL after a failover. In the lab, 1.1.1.1 returned old and new answers alternately until about 64 s with a 60 s TTL. Lower TTLs are possible, but some resolvers raise them anyway.

`FLUXER_HA_DNS_TTL` defaults to 60 s. Cloudflare rejects anything lower ("TTL must be between 60 and 86400 seconds, or 1 for Automatic"). `1` means Cloudflare's *automatic*, which its documentation puts at 300 s for DNS-only records: slower, not faster. Don't use it.

## Health checks

While a site is the spare, `ha-health.sh` checks that public DNS (asked through `FLUXER_HA_DNS_CHECK_RESOLVER`, default 1.1.1.1) points at the **peer**. After a failback, `failback.sh` checks that it points at this site before declaring success. Both are skipped with `none`.

