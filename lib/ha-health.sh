#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Health heartbeat. Runs every 30 s on BOTH sites (fluxer-ha-health.timer).
# On every site it checks the WireGuard firewall. The rest runs only on the
# REPLICA, which pings FLUXER_HA_HEARTBEAT_URL only when the cluster could
# survive losing the primary right now. Your monitor alerts when the pings
# stop: "no automatic failover is possible at the moment". That includes the
# replica itself being down. failback.sh reuses these checks.
set -eu
HA_NAME=ha-health
. "$(dirname "$0")/common.sh"
HEARTBEAT_URL=$(envget FLUXER_HA_HEARTBEAT_URL)
PEER_SSH=$(envget FLUXER_HA_PEER_SSH)

fail() { echo "ha-health FAILED: $1" >&2; exit 1; }

# 0. On EVERY site, primary included: the WireGuard firewall is in place.
#    iptables needs CAP_NET_ADMIN, so fluxer-ha-firewall-check.timer, which
#    has it, checks (and re-applies) the rules every 30 s and writes the
#    result; this script has no capabilities and only reads it.
fw=$(cat "$STATE_DIR/firewall.status" 2>/dev/null || echo "missing")
fw_at=$(say "$fw" | awk '{print $2}')
case $fw in
	ok\ *) [ $(( $(date +%s) - ${fw_at:-0} )) -le 120 ] || fail "firewall status is stale (is fluxer-ha-firewall-check.timer running?)" ;;
	*) fail "firewall: ${fw}" ;;
esac

# 0a. On EVERY site: Valkey that can't load its append-only file is repaired,
#     and the damaged files kept (lab F49; valkey-repair.sh).
. ./fluxer-ha/valkey-repair.sh
valkey_repair

# Only the replica reports. The primary is covered by the public probes.
curl -fsS -m 2 -o /dev/null http://127.0.0.1:8008/replica 2>/dev/null || exit 0

# 0b. A spare the primary can no longer feed never catches up on its own. Once
#     the primary has dropped this node's replication slot (member_slots_ttl)
#     or capped it (max_slot_wal_keep_size), and recycled the WAL this node
#     still needs, Postgres retries "requested WAL segment ... has already been
#     removed" every 5 s forever, and Patroni doesn't re-clone it (lab F35).
#     That error can only come from a live primary refusing this node's
#     position, so a newer, serving copy exists: re-clone from it. At most once
#     an hour; Patroni's reinitialize wipes and re-copies this node only.
#     Only acts if the LATEST such error is under 2 min old (Postgres's own
#     UTC timestamp) and Patroni reports this member as not streaming, so
#     lines left in the log by an earlier incident can't trigger it. (The
#     last 200 lines, not `docker logs --since`, which returned nothing at
#     all on Docker 29.9: lab F36.)
me=$(envget FLUXER_HA_SITE)
members=$(docker compose exec -T postgres /opt/patroni/bin/patronictl -c /etc/patroni.yml list -f json </dev/null 2>/dev/null || echo '[]')
my_state=$(printf '%s\n' "$members" | jq -r --arg m "$me" '.[] | select(.Member == $m) | .State' 2>/dev/null || true)
last_err=$(docker compose logs --no-color --tail 200 postgres 2>/dev/null | grep 'requested WAL segment .* has already been removed' |
	tail -n 1 | grep -o '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -n 1)
err_age=999999
[ -z "$last_err" ] || err_age=$(( $(date +%s) - $(date -u -d "$last_err" +%s 2>/dev/null || echo 0) ))
if [ -n "$my_state" ] && [ "$my_state" != streaming ] && [ "$err_age" -le 120 ]; then
	leader=$(printf '%s\n' "$members" | jq -r '.[] | select(.Role == "Leader") | .Member' 2>/dev/null || true)
	last=$(cat "$STATE_DIR/reinit-at" 2>/dev/null || echo 0)
	if [ -n "$leader" ] && [ "$leader" != "$me" ] && [ $(( $(date +%s) - last )) -ge 3600 ]; then
		date +%s >"$STATE_DIR/reinit-at"
		msg="the primary ($leader) no longer has the WAL this spare needs; re-cloning $me from it"
		au=$(envget FLUXER_HA_ALERT_URL)
		[ -z "$au" ] || printf 'url = "%s"\n' "$au" | curl -fsS -m 5 --config - -d "fluxer-ha $me: $msg" >/dev/null 2>&1 || true
		echo "ha-health: $msg" >&2
		docker compose exec -T postgres /opt/patroni/bin/patronictl -c /etc/patroni.yml reinit fluxer "$me" --force </dev/null >&2 || true
	fi
	fail "this spare can't catch up from the primary (WAL already removed); re-clone started or pending"
fi

# 1. This replica is the synchronous standby, so it is eligible for automatic promotion.
#    Patroni's /sync answers 200 only on the sync standby (lab, Patroni 4.1.5:
#    200 there, 503 on the primary).
curl -fsS -m 2 -o /dev/null http://127.0.0.1:8008/sync || fail "not the synchronous standby"

# 2. All three etcd members are healthy, so a quorum without the primary is possible.
#    etcdctl ships in the etcd image (lab: 3.6.15).
docker compose exec -T etcd etcdctl --endpoints="$(envget FLUXER_HA_ETCD_HOSTS)" endpoint health >/dev/null 2>&1 ||
	fail "etcd: not all members healthy (the witness or a site is down)"

# 3. Valkey is replicating from the primary. (valkey-cli authenticates with
#    REDISCLI_AUTH from the container's environment.)
vinfo=$(docker compose exec -T valkey valkey-cli INFO replication | tr -d '\r')
echo "$vinfo" | grep -q '^master_link_status:up$' || fail "valkey link down"

# 4. Media replication is running: filer.sync (seconds) and the rclone
#    push-back/reconcile (hourly).
for svc in filer-sync s3-mirror; do
	cid=$(docker compose ps -q "$svc")
	[ -n "$cid" ] && [ "$(docker inspect --format '{{.State.Health.Status}}' "$cid")" = "healthy" ] || fail "$svc unhealthy"
done

# 4b. Objects s3-mirror skips because they can't be read on the other side
#     (lab F52). Failover doesn't depend on them, so they don't fail this
#     check: their records are copied to fluxer-ha/errors/s3-mirror/, and you
#     get an alert whenever the list changes.
mcid=$(docker compose ps -q s3-mirror)
skipped=$(docker exec "$mcid" sh -c 'cat /state/unreadable-*.txt 2>/dev/null' 2>/dev/null || true)
if [ -n "$skipped" ]; then
	mkdir -p fluxer-ha/errors/s3-mirror && chmod 700 fluxer-ha/errors fluxer-ha/errors/s3-mirror
	docker cp "$mcid:/state/errors/." fluxer-ha/errors/s3-mirror/ >/dev/null 2>&1 || true
	sk=$(printf '%s\n' "$skipped" | sort | sha256sum | cut -c1-16)
	if [ "$sk" != "$(cat "$STATE_DIR/s3-skipped" 2>/dev/null)" ]; then
		echo "$sk" >"$STATE_DIR/s3-skipped"
		alert "s3-mirror skips $(printf '%s\n' "$skipped" | wc -l) object(s) it can't read, so they're missing on this spare; failover isn't affected. Details in $(pwd)/fluxer-ha/errors/s3-mirror"
	fi
	echo "ha-health WARNING: s3-mirror skips $(printf '%s\n' "$skipped" | wc -l) unreadable object(s); see fluxer-ha/errors/s3-mirror" >&2
else
	rm -f "$STATE_DIR/s3-skipped"
fi

# 5. Controller running, clock OK, shared config identical on both sites.
systemctl is-active --quiet fluxer-ha-controller || fail "controller not running"
offset=$(chronyc tracking 2>/dev/null | awk '/^System time/ {print $4}')
[ -n "$offset" ] && awk -v o="$offset" 'BEGIN { exit !(o < 0.1) }' || fail "clock offset ${offset:-unknown}"
if [ -n "$PEER_SSH" ]; then
	# The shared settings and the image lock (fluxer-ha/pin-images.sh) must match.
	# Same computation as ssh-gate.sh env-hash.
	here=$(cat fluxer-ha/.env.shared fluxer-ha/ha.images.lock.yml 2>/dev/null | sha256sum | cut -d' ' -f1)
	# The peer's forced command (ssh-gate.sh) only answers fixed verbs.
	there=$(ssh_peer "$PEER_SSH" env-hash)
	[ "$here" = "$there" ] || fail "fluxer-ha/.env.shared or fluxer-ha/ha.images.lock.yml differs between sites (they must be byte-identical; compare sha256sum on both)"
fi

# 5b. Nothing edited the generated .env directly. Upstream's install.sh --update
#     writes newly required secrets there; until they're in fluxer-ha/.env.shared on both
#     sites they would be lost at the next rebuild, or differ between sites.
#     build-env.sh records a hash of every line it wrote (fluxer-ha/.env.built).
if [ -f fluxer-ha/.env.built ]; then
	sums() { grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | while IFS= read -r l; do printf '%s %s\n' "${l%%=*}" "$(printf '%s' "$l" | sha256sum | cut -c1-64)"; done | sort; }
	srcsums=$(mktemp); cat fluxer-ha/.env.shared fluxer-ha/.env.site | sums >"$srcsums"
	edited=$(sums <.env | comm -23 - fluxer-ha/.env.built | comm -23 - "$srcsums" | cut -d' ' -f1 | sort -u | tr '\n' ' ')
	rm -f "$srcsums"
	[ -z "$edited" ] || fail ".env was edited directly (move these into fluxer-ha/.env.shared on both sites, then fluxer-ha/build-env.sh): $edited"
fi

# 6. Public DNS points at the primary (the peer of this replica), when the HA
#    layer manages DNS. FLUXER_HA_DNS_CHECK_RESOLVER (default 1.1.1.1) stands
#    in for "what users resolve". Needs dig.
DNS_NAME=$(envget FLUXER_HA_DNS_NAME)
PEER_IPV4=$(envget FLUXER_HA_PEER_PUBLIC_IPV4)
PROVIDER=$(envget FLUXER_HA_DNS_PROVIDER)
RESOLVER=$(envget FLUXER_HA_DNS_CHECK_RESOLVER); RESOLVER=${RESOLVER:-1.1.1.1}
if [ "${PROVIDER:-none}" != none ] && [ -n "$DNS_NAME" ] && [ -n "$PEER_IPV4" ]; then
	resolved=$(dig +short A "$DNS_NAME" @"$RESOLVER" | tail -n 1)
	[ "$resolved" = "$PEER_IPV4" ] || fail "DNS $DNS_NAME -> ${resolved:-nothing}, expected primary $PEER_IPV4"
fi

# 7. Keep etcd leadership on the witness (docs/lab-results.md F11). When an
#    etcd leader dies, the new leader renews every lease to its full TTL. If a
#    site is the etcd leader and the Patroni primary at once, its death keeps
#    the Patroni leader key alive for up to another ttl, delaying failover, and
#    a fast-rebooting old primary can reclaim it. The witness runs no Postgres,
#    so leadership there is never lost together with the primary.
#    Best effort, in a subshell: a failure only logs and never withholds the
#    heartbeat. Needs jq on the host.
(
	ETCD_EPS=$(envget FLUXER_HA_ETCD_HOSTS)
	WITNESS_EP=$(echo "$ETCD_EPS" | tr ',' '\n' | grep -v "^$(envget FLUXER_HA_LOCAL_WG_IP):" | grep -v "^$(envget FLUXER_HA_PEER_WG_IP):" | head -n 1)
	[ -n "$WITNESS_EP" ] || exit 0
	st=$(docker compose exec -T etcd etcdctl --endpoints="$ETCD_EPS" endpoint status -w json 2>/dev/null) || exit 0
	leader=$(printf '%s\n' "$st" | jq -r '.[0].Status.leader | tostring')
	witness_id=$(printf '%s\n' "$st" | jq -r --arg ep "$WITNESS_EP" '.[] | select(.Endpoint == $ep) | .Status.header.member_id | tostring')
	leader_ep=$(printf '%s\n' "$st" | jq -r --arg id "$leader" '.[] | select((.Status.header.member_id | tostring) == $id) | .Endpoint')
	[ -n "$witness_id" ] && [ -n "$leader_ep" ] && [ "$leader" != "$witness_id" ] || exit 0
	if docker compose exec -T etcd etcdctl --endpoints="$leader_ep" move-leader "$(printf '%x' "$witness_id")" >/dev/null 2>&1; then
		echo "ha-health: moved etcd leadership from $leader_ep to the witness ($WITNESS_EP)"
	else
		echo "ha-health: could not move etcd leadership to the witness" >&2
	fi
) || true

# 8. This site runs the configuration on disk. After an edit or an upgrade the
#    containers keep their old image and settings until fluxer-ha rollout applies
#    them (the controller never does: F27). A spare that wasn't rolled out
#    must not count as healthy, or failback would move the primary onto old
#    code. Only the data and warm tiers are compared: the controller creates
#    the cold tier from the current configuration whenever this site is
#    promoted.
. ./fluxer-ha/tiers.sh
# shellcheck disable=SC2086
pending=$(docker compose --profile app --dry-run up -d --no-deps $DATA $WARM 2>&1 |
	sed -n "s/^ *Container $PROJECT-\\(.*\\)-1 Recreate *\$/\\1/p" | sort -u | tr '\n' ' ')
# s3-mirror reads its script through a bind mount; an updated script reaches
# it only when it's recreated, which Compose doesn't see as a change.
mcid=$(docker compose ps -q s3-mirror)
[ -z "$mcid" ] || docker exec "$mcid" cat /s3-mirror.sh 2>/dev/null | cmp -s - fluxer-ha/s3-mirror.sh || pending="${pending}s3-mirror(script) "
[ -z "$pending" ] || fail "configuration not applied on this site (run fluxer-ha rollout): $pending"

# 9. This spare holds a certificate it could serve for the Fluxer domain the
#    moment it's promoted: valid for the name, trusted by this host, and not
#    past the point where Caddy would renew it (a third of its lifetime left).
#    The primary copies its certificate here hourly (fluxer-ha-certs.timer).
#    Without this check a failover could land on a spare holding no copy, or
#    a stale one, and the heartbeat would still report a safe pair: in the
#    lab a switchover came before the first copy and the new primary served
#    an untrusted certificate (F40). Cached for 5 min: reading the bundled
#    edge's volume starts a container.
cert_check() {
	mode=$(envget FLUXER_HA_CERT_MODE); dom=$(envget FLUXER_DOMAIN); dom=${dom:-$DNS_NAME}
	tmpd=$(mktemp -d); chain=$tmpd/chain.pem; leaf=$tmpd/leaf.pem
	case ${mode:-none} in
		none) rm -rf "$tmpd"; echo ok; return ;;
		caddy)
			# The proxy keeps running on the spare for your other sites, and
			# completes the TLS handshake even though it then aborts the request.
			echo | openssl s_client -connect 127.0.0.1:443 -servername "$dom" -showcerts 2>/dev/null |
				sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' >"$chain" ;;
		edge)
			util=$(envget FLUXER_HA_UTIL_IMAGE); util=${util:-alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6}
			docker run --rm -v "${PROJECT}_edge-data":/d:ro "$util" sh -c "cat /d/caddy/certificates/*/$dom/$dom.crt" >"$chain" 2>/dev/null ;;
		*) rm -rf "$tmpd"; echo "unknown FLUXER_HA_CERT_MODE '$mode'"; return ;;
	esac
	sed -n '1,/-END CERTIFICATE-/p' "$chain" >"$leaf"
	if ! openssl x509 -in "$leaf" -noout 2>/dev/null; then why="no certificate for $dom on this spare (has the primary copied it? fluxer-ha-certs.timer)"
	elif ! openssl x509 -in "$leaf" -noout -checkhost "$dom" 2>/dev/null | grep -q 'does match'; then why="the certificate on this spare isn't for $dom"
	elif ! openssl verify -untrusted "$chain" "$leaf" >/dev/null 2>&1; then why="the certificate on this spare for $dom isn't trusted here (a copy from the primary hasn't arrived?)"
	else
		nb=$(date -u -d "$(openssl x509 -in "$leaf" -noout -startdate | cut -d= -f2)" +%s)
		na=$(date -u -d "$(openssl x509 -in "$leaf" -noout -enddate | cut -d= -f2)" +%s)
		left=$((na - $(date +%s))); life=$((na - nb))
		if [ "$left" -le 0 ]; then why="the certificate on this spare for $dom has expired"
		elif [ $((left * 3)) -lt "$life" ]; then why="the certificate on this spare for $dom is past its renewal point ($((left / 3600)) h left): the primary's copy isn't arriving"
		else why=ok; fi
	fi
	rm -rf "$tmpd"; echo "$why"
}
cc=$STATE_DIR/cert-check
if [ $(( $(date +%s) - $(stat -c %Y "$cc" 2>/dev/null || echo 0) )) -ge 300 ]; then
	cert_check >"$cc.tmp" && mv -f "$cc.tmp" "$cc"
fi
cres=$(cat "$cc" 2>/dev/null || echo "certificate check didn't run")
[ "$cres" = ok ] || fail "$cres"

# failback.sh reuses these checks with HA_HEALTH_NO_PING=1.
[ -n "${HA_HEALTH_NO_PING:-}" ] || [ -z "$HEARTBEAT_URL" ] || curl_cfg_url "$HEARTBEAT_URL" | curl -fsS -m 10 --config - >/dev/null
echo "ha-health OK"
