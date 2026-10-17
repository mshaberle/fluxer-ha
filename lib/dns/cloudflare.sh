# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=sh
#
# DNS provider: Cloudflare, DNS only (proxied=false, the grey cloud). Cloudflare
# answers DNS queries and never sees or terminates the traffic. Tested in the
# lab (2026-10-15).
#
#   FLUXER_HA_CF_API_TOKEN       scoped token, Zone.DNS:Edit on this one zone
#   FLUXER_HA_CF_ZONE_ID
#   FLUXER_HA_CF_RECORD_ID_A     the A record for FLUXER_HA_DNS_NAME
#   FLUXER_HA_CF_RECORD_ID_AAAA  optional
#
# Every call re-reads the settings, so fixing .env takes effect on the next
# retry (lab F15).

dns_configured() {
	[ -n "$(envget FLUXER_HA_CF_API_TOKEN)" ] && [ -n "$(envget FLUXER_HA_CF_ZONE_ID)" ] &&
		[ -n "$(envget FLUXER_HA_CF_RECORD_ID_A)" ]
}

# dns_update A|AAAA <ip>
dns_update() {
	case $1 in A) rec=$(envget FLUXER_HA_CF_RECORD_ID_A) ;; AAAA) rec=$(envget FLUXER_HA_CF_RECORD_ID_AAAA) ;; *) return 1 ;; esac
	[ -n "$rec" ] || return 0
	ttl=$(envnum FLUXER_HA_DNS_TTL 60)
	# The token reaches curl on stdin, never in argv.
	printf 'header = "Authorization: Bearer %s"\n' "$(envget FLUXER_HA_CF_API_TOKEN)" |
		curl -sS -m 10 --config - -X PATCH -H 'Content-Type: application/json' \
			--data "{\"content\":\"$2\",\"proxied\":false,\"ttl\":$ttl}" \
			"https://api.cloudflare.com/client/v4/zones/$(envget FLUXER_HA_CF_ZONE_ID)/dns_records/$rec" 2>&1 |
		grep -q '"success":[[:space:]]*true'
}
