#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Turns on etcd authentication with two users:
#   root     etcd's administrator. Only the sites' etcdctl uses it (ha-health,
#            the game-day scripts), through ETCDCTL_USER in the etcd container.
#   patroni  read/write on Patroni's namespace (/fluxer/) and nothing else.
# Both passwords come from fluxer-ha/.env.shared. Neither ever goes on a command line:
# etcdctl reads them on stdin.
#
#   etcd-auth.sh users    create or update both users and the role (auth stays off)
#   etcd-auth.sh enable   check Patroni can log in, then turn auth on
#   etcd-auth.sh status   print whether auth is on
#
# Order for an existing cluster (docs/operations.md, "Turning on etcd auth"): `users`, then give Patroni its
# credentials (a rolling recreate of postgres), then `enable`. Patroni accepts
# credentials while auth is still off ("Etcd authentication is not enabled",
# patroni/dcs/etcd3.py), so nothing breaks in between.
#
# What this protects against: containers and local users on a site, which can
# reach etcd on the WireGuard address. It does NOT protect against a
# compromised etcd MEMBER (the witness): a member takes part in Raft and holds
# the data on disk. See docs/security.md, "The witness is inside the trust boundary".
set -eu
cd "$(dirname "$0")/.."

envget() { sed -n "s/^$1=//p" .env | tail -n 1; }
EPS=$(envget FLUXER_HA_ETCD_HOSTS)
ROOT_PW=$(envget FLUXER_HA_ETCD_ROOT_PASSWORD)
PATRONI_PW=$(envget FLUXER_HA_ETCD_PATRONI_PASSWORD)
[ -n "$ROOT_PW" ] && [ -n "$PATRONI_PW" ] ||
	{ echo "etcd-auth: set FLUXER_HA_ETCD_ROOT_PASSWORD and FLUXER_HA_ETCD_PATRONI_PASSWORD in fluxer-ha/.env.shared" >&2; exit 1; }

# etcdctl as root. The etcd container gets ETCDCTL_USER from ha.compose.yml;
# it is passed again here so this works before that container is recreated.
# `-e ETCDCTL_USER` without a value copies it from this script's environment,
# so the password stays off docker's command line.
ctl() { ETCDCTL_USER="root:$ROOT_PW" docker compose exec -T -e ETCDCTL_USER etcd etcdctl --endpoints="$EPS" "$@"; }
ctl_noauth() { docker compose exec -T etcd etcdctl --endpoints="$EPS" "$@"; }

auth_on() { ctl_noauth auth status </dev/null 2>/dev/null | grep -q '^Authentication Status: true'; }

# `user add` fails if the user exists; `passwd` fails if it doesn't. Try both.
set_user() {
	name=$1; pw=$2
	if ! printf '%s\n' "$pw" | ctl user add "$name" --interactive=false >/dev/null 2>&1; then
		printf '%s\n' "$pw" | ctl user passwd "$name" --interactive=false >/dev/null
	fi
}

users() {
	set_user root "$ROOT_PW"
	ctl user grant-role root root </dev/null >/dev/null 2>&1 || true
	ctl role add patroni </dev/null >/dev/null 2>&1 || true
	ctl role grant-permission patroni --prefix=true readwrite /fluxer/ </dev/null >/dev/null
	set_user patroni "$PATRONI_PW"
	ctl user grant-role patroni patroni </dev/null >/dev/null 2>&1 || true
	echo "etcd-auth: users root and patroni ready (auth is $(auth_on && echo on || echo off))"
}

# etcdctl as the patroni user, to prove its grant before and after auth is on.
ctl_patroni() { ETCDCTL_USER="patroni:$PATRONI_PW" docker compose exec -T -e ETCDCTL_USER etcd etcdctl --endpoints="$EPS" "$@"; }
patroni_running() { docker compose ps --status running --services 2>/dev/null | grep -qx postgres; }

enable() {
	if auth_on; then echo "etcd-auth: already on"; return 0; fi
	ctl role get patroni </dev/null | grep -q '/fluxer/' || { echo "etcd-auth: role patroni has no /fluxer/ grant; run 'users' first" >&2; exit 1; }
	# On a running cluster, Patroni must already hold its credentials, or
	# turning auth on cuts it off from etcd. On a new cluster (migrate)
	# Patroni hasn't started yet, and gets them from its first start.
	if patroni_running; then
		docker compose exec -T postgres sh -c 'test -n "$PATRONI_ETCD3_USERNAME" && test -n "$PATRONI_ETCD3_PASSWORD"' </dev/null ||
			{ echo "etcd-auth: this site's Patroni has no etcd credentials yet; roll out first" >&2; exit 1; }
	fi
	ctl auth enable </dev/null
	# Prove the patroni user can write and delete under its prefix, with auth
	# on. (Patroni reads only /fluxer/<scope>/, so this key never confuses it.)
	if ! { ctl_patroni put /fluxer/.etcd-auth-check ok </dev/null >/dev/null 2>&1 &&
		ctl_patroni del /fluxer/.etcd-auth-check </dev/null >/dev/null 2>&1; }; then
		echo "etcd-auth: the patroni user can't write /fluxer/ with auth on; turning auth off again" >&2
		ctl auth disable </dev/null; exit 1
	fi
	if patroni_running; then
		sleep 6
		docker compose exec -T postgres /opt/patroni/bin/patronictl -c /etc/patroni.yml list </dev/null >/dev/null ||
			{ echo "etcd-auth: Patroni can't read etcd with auth on; turning auth off again" >&2; ctl auth disable </dev/null; exit 1; }
	fi
	echo "etcd-auth: on"
}

case "${1:-}" in
	users) users ;;
	enable) enable ;;
	status) auth_on && echo on || echo off ;;
	*) echo "usage: etcd-auth.sh users|enable|status" >&2; exit 2 ;;
esac
