# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=sh
#
# Sourced by every fluxer-ha runtime script. The scripts live in <fluxer>/fluxer-ha/,
# so this moves to <fluxer>, the directory holding docker-compose.yml and .env.
# Set HA_NAME before sourcing; it labels log lines.
#
# Settings are read with sed, never by sourcing .env: a value in .env is data,
# not shell.
cd "$(dirname "$0")/.." || exit 1

envget() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -n 1; }
envnum() { v=$(envget "$1"); echo "${v:-$2}"; }

SITE=$(envget FLUXER_HA_SITE)
ALERT_URL=$(envget FLUXER_HA_ALERT_URL)
# `name: fluxer` in upstream's docker-compose.yml
PROJECT=$(envget COMPOSE_PROJECT_NAME); PROJECT=${PROJECT:-fluxer}
# Owned by the user the services run as (`fluxer-ha install` creates it).
# State, locks, the SSH key and the DNS log all live here, so nothing but
# As the units' UMask=0027, also when run by hand from a login shell (audit H2).
umask 027
# the firewall needs root at run time.
STATE_DIR=${FLUXER_HA_STATE_DIR:-$(pwd)/fluxer-ha/state}
SSH_KEY=$STATE_DIR/ssh/id_ed25519
ssh_peer() {
	ssh -i "$SSH_KEY" -o UserKnownHostsFile="$STATE_DIR/ssh/known_hosts" -o BatchMode=yes -o ConnectTimeout=5 "$@"
}

log() { echo "$(date -u +%FT%TZ) ${HA_NAME:-fluxer-ha}[$SITE]: $*"; }
# Secrets never go on a command line, where any local user can read them
# from /proc. curl gets them on stdin as a config file instead (--config -).
# Values are expected to be hex or URL-safe; a double quote would end the
# config string.
curl_cfg_url() { printf 'url = "%s"\n' "$1"; }
alert() {
	log "ALERT: $*"
	[ -z "$ALERT_URL" ] || curl_cfg_url "$ALERT_URL" | curl -fsS -m 5 --config - -d "fluxer-ha $SITE: $*" >/dev/null 2>&1 || true
}

# Patroni's REST API. GETs need no password; anything that changes state does.
api_code() { curl -s -m 2 -o /dev/null -w '%{http_code}' "http://$1:8008/$2" 2>/dev/null || true; }
api() { [ "$(api_code "$1" "$2")" = 200 ]; }
is_primary() { api 127.0.0.1 primary; }
is_replica() { api 127.0.0.1 replica; }

# POST to Patroni with the REST password from stdin. Prints the body, then the
# HTTP code on the last line.
patroni_post() {
	node=$1; path=$2; body=$3; timeout=${4:-90}
	printf 'user = "patroni:%s"\n' "$(envget FLUXER_HA_PATRONI_API_PASSWORD)" |
		curl -sS -m "$timeout" --config - -w '\n%{http_code}' -X POST \
			-H 'Content-Type: application/json' -d "$body" "http://$node:8008/$path" 2>&1
}

# printf, not echo: dash's echo rewrites backslash escapes, which corrupts JSON.
say() { printf '%s\n' "$*"; }
