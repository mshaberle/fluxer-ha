# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=sh
#
# DNS provider: your own program, for any DNS API this project doesn't ship.
#
#   FLUXER_HA_DNS_HOOK   absolute path to an executable owned by root or by the
#                        user the services run as, and writable by no one else
#
# Called as:  <hook> <name> <A|AAAA> <ip> <ttl>
# Exit 0 only once the record holds <ip>. It is retried with back-off until
# it succeeds or this site stops being the primary, so it must be safe to
# run again. Its own secrets belong in a file it reads, not in its argv.
# Lab-tested with a Cloudflare hook (docs/dns.md); test your own before relying on it.

dns_configured() {
	h=$(envget FLUXER_HA_DNS_HOOK)
	[ -n "$h" ] && [ -x "$h" ] || return 1
	# Refuse a hook another user could replace: the file, or its directory
	# (whoever can write the directory can swap the file).
	for p in "$h" "$(dirname "$h")"; do
		o=$(stat -L -c %u "$p")
		{ [ "$o" = 0 ] || [ "$o" = "$(id -u)" ]; } && [ -z "$(find -L "$p" -maxdepth 0 -perm /022)" ] || return 1
	done
}

dns_update() {
	"$(envget FLUXER_HA_DNS_HOOK)" "$(envget FLUXER_HA_DNS_NAME)" "$1" "$2" "$(envnum FLUXER_HA_DNS_TTL 60)"
}
