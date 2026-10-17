# TLS and reverse proxies

The Fluxer **edge** (upstream's Caddy container) is part of the cold tier: it runs on the primary only. What sits in front of it decides how certificates and stale clients are handled.

## Bundled TLS (`install.sh --tls bundled`, the default)

The edge binds 80 and 443 and gets its own certificate with HTTP-01. On the spare the edge isn't running, so **nothing listens on 80/443 there**: a client that still has the old address gets "connection refused" and retries, which is the cleanest possible fence.

- `FLUXER_HA_CERT_MODE=edge`. The primary copies its certificate into the spare's `edge-data` volume hourly (and 2 min after boot), so a newly promoted site starts with a valid certificate. No restart is needed, because the edge on the spare only starts at promotion.
- Renewals happen on whichever site is primary; HTTP-01 works there because DNS points there.
- **Lab status:** tested with `FLUXER_EDGE_GLOBAL_OPTIONS=local_certs` (a local CA, because the lab isn't public) in runs 1–5 ([lab-results.md](lab-results.md)). **Not tested with Let's Encrypt.**

## Your own reverse proxy (`--tls proxy`)

Fluxer serves plain HTTP on `127.0.0.1:8080`, or on the edge's container name with `ha.proxy-network.yml`, and your proxy terminates TLS. Two things to get right.

**1. Forward only to the edge.** Never route straight to `gateway` or `media-proxy`: they run on both sites (the warm tier), so the spare would serve them.

**2. Close the connection when the edge is gone.** On the spare, your proxy keeps running for your other sites, and answers 502 for Fluxer. Browsers keep their HTTP/1.1 keep-alive and HTTP/2 connections open and reuse them, so they keep hitting the spare long after DNS has moved. In the lab that left a client on the dead site for **minutes** (lab finding F16). The fix is to **abort** the connection on 502/503/504, so the client reconnects and resolves the name again.

### Caddy (tested, as a snippet too)

```caddyfile
chat.example.com {
	reverse_proxy fluxer-edge-1:8080      # or 127.0.0.1:8080 if Caddy runs on the host
	handle_errors 502 503 504 {
		abort
	}
}
```

The same thing as a snippet, if your Caddy serves several sites:

```caddyfile
(fluxer_edge) {
	reverse_proxy fluxer-edge-1:8080
	handle_errors 502 503 504 {
		abort
	}
}

chat.example.com {
	import fluxer_edge
}
```

For a Caddy in Docker, as above, the edge has to be on Caddy's network: `fluxer-ha init --proxy-network caddy_default` adds `ha.proxy-network.yml`, so you don't have to edit upstream's `docker-compose.proxy.yml` (which `install.sh --update` would overwrite).

**Check it:** run `HA_GAMEDAY=1 fluxer-ha/tests/gd-proxy-fence.sh <your other sites>` on both sites ([testing.md](testing.md)). Without the `abort`, it fails on the spare and says so.

**If your Caddyfile is bind-mounted as a single file** (`./Caddyfile:/etc/caddy/Caddyfile`), edit it **in place**. `sed -i`, and editors that save by writing a new file and renaming it, give the file a new inode. The container keeps seeing the old one, so `caddy reload` silently reloads your *old* config. This caught the lab's own test. Either edit in place (`cat new > Caddyfile`), recreate the container after editing, or mount the directory instead of the file.

Certificates: `FLUXER_HA_CERT_MODE=caddy`, `FLUXER_HA_CADDY_DATA_VOLUME=<the volume holding Caddy's /data>`, `FLUXER_HA_CADDY_CONTAINER=<its container name>`. The spare's Caddy is restarted to load a copied certificate, because a reload keeps the cached one (F6). That's at most once an hour, and normally once per renewal (about every 60 days). Each restart interrupts the other sites on that Caddy for about half a second.

### nginx (1.29, tested in front of a running pair)

`return 444` makes nginx close the connection without answering, but **only over HTTP/1.1**. Over HTTP/2 it resets just that one stream and keeps the connection open, so a browser stays on the spare (lab, nginx 1.29: 1 connection for 2 requests). Turn HTTP/2 off **in the Fluxer server block only**. Your other sites on the same port keep it (lab: the other server stayed on HTTP/2, and the Fluxer name closed its connection on every request).

```nginx
server {
    listen 443 ssl;
    http2 off;                 # 444 must close the connection, not just a stream
    server_name chat.example.com;
    # ssl_certificate ...;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;   # map $http_upgrade in http {}
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 1h;                             # the gateway WebSocket
        proxy_intercept_errors on;
        error_page 502 503 504 = @gone;
    }
    location @gone { return 444; }
}
```

**nginx in Docker, on your proxy's network (`--proxy-network`)**: don't name the edge in `proxy_pass` directly. nginx resolves a name in `proxy_pass` once, at startup, and the spare has no edge container. Lab, nginx 1.29.8 on the spare with `proxy_pass http://fluxer-edge-1:8080;`: it exited with `host not found in upstream "fluxer-edge-1"`. That nginx would also be down for every other site it serves, and again after each reboot of the spare. Look it up per request through Docker's DNS instead:

```nginx
    resolver 127.0.0.11 valid=5s ipv6=off;   # Docker's DNS
    set $edge fluxer-edge-1;                 # <project>-edge-1
    location / {
        proxy_pass http://$edge:8080;
        # ... the rest as above
    }
```

Lab, 2026-10-16, with that, `http2 off` and the `@gone` 444 above, in nginx containers on `caddy_default` on both sites of a running pair: each started on its site whatever the role. After an automatic failback and a hard power-off, with no reload, the new primary's nginx answered 200 and kept its connection, and the spare's closed every connection unanswered (curl exit 56).

**Certificates:** `FLUXER_HA_CERT_MODE=none`. fluxer-ha copies nothing then, so each site needs its own valid certificate before it can serve: DNS-01 renewal on both sites works whatever the role. HTTP-01 works only on the site DNS points at, so the spare's copy goes stale unless you copy it yourself, and a failover then serves an expired or missing certificate until certbot has run on the new primary.

### Traefik (no equivalent of abort; tested in isolation, 3.5.6)

Traefik has no way to close a connection instead of answering an error. The errors middleware can only serve an error page, and it keeps the error's status. Lab, Traefik 3.5.6 with a dead backend: two requests on one connection both got **502** and the second **reused** the connection, over HTTP/1.1 and HTTP/2 alike, with or without the errors middleware. So clients pinned to the spare keep getting 502 until their connection closes. Two mitigations:
- shorten idle connections on the entrypoint (`entryPoints.websecure.transport.respondingTimeouts.idleTimeout`), which affects every site on that Traefik;
- or put Fluxer on its own entrypoint or IP.

Prefer the bundled edge, Caddy or nginx if you can. Certificates: `FLUXER_HA_CERT_MODE=none` (Traefik's ACME storage isn't Caddy's layout).

## Checking the fence

With the primary on site 1:

```sh
curl -sv --resolve chat.example.com:443:<site 2 public IP> https://chat.example.com/api/_health
```

- **Bundled TLS:** expect "connection refused".
- **Your own proxy:** expect the connection to close with no response ("empty reply" or a reset), not a 502 page.
