#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Copies the Fluxer certificate from the PRIMARY to the replica, hourly
# (fluxer-ha-certs.timer). With HTTP-01 only the site DNS points at can obtain
# or renew it, so without this copy a newly promoted site would have to get a
# certificate first. Only the Fluxer domain's directory is copied; other
# sites' certificates on either host are never touched. The peer's SSH gate
# (cert-receive) checks the archive and refuses if the peer is the primary.
#
# FLUXER_HA_CERT_MODE: edge (upstream's bundled edge, the edge-data volume),
# caddy (your own Caddy container's data volume), or none (skip: you handle
# certificates, for example with DNS-01 on both sites).
# Caddy's storage layout, <data>/caddy/certificates/<issuer>/<domain>/: the
# lab copied it with Caddy 2.11.7, as upstream's edge and as your own Caddy.
# A future Caddy that changed the layout would make the spare's health check
# fail (no trusted certificate), not serve a stale one.
set -eu
HA_NAME=sync-edge-certs
. "$(dirname "$0")/common.sh"

is_primary || exit 0
MODE=$(envget FLUXER_HA_CERT_MODE)
case ${MODE:-none} in
	edge) VOLUME=${PROJECT}_edge-data ;;
	caddy) VOLUME=$(envget FLUXER_HA_CADDY_DATA_VOLUME) ;;
	none) exit 0 ;;
	*) echo "unknown FLUXER_HA_CERT_MODE '$MODE'" >&2; exit 1 ;;
esac
PEER_SSH=$(envget FLUXER_HA_PEER_SSH)
# The certificate is for the name the edge or your proxy serves: FLUXER_DOMAIN.
DOMAIN=$(envget FLUXER_DOMAIN); DOMAIN=${DOMAIN:-$(envget FLUXER_HA_DNS_NAME)}
[ -n "$PEER_SSH" ] || { echo "FLUXER_HA_PEER_SSH not set" >&2; exit 1; }
[ -n "$DOMAIN" ] && [ -n "$VOLUME" ] || { echo "no domain or certificate volume configured" >&2; exit 1; }
UTIL_IMAGE=$(envget FLUXER_HA_UTIL_IMAGE)
UTIL_IMAGE=${UTIL_IMAGE:-alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6}

docker run --rm -v "$VOLUME":/src:ro "$UTIL_IMAGE" sh -c "cd /src && tar -cf - caddy/certificates/*/$DOMAIN" |
	ssh_peer "$PEER_SSH" cert-receive
