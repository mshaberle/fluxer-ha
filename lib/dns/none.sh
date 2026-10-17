# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=sh
#
# DNS provider: none. The HA layer never changes DNS. Use it when something
# else moves traffic to the primary: a floating IP your provider moves for
# you, a load balancer health-checking both sites' /_health, or a manual
# step (then failover is no longer fully automatic for users).
# The DNS checks in ha-health.sh and failback.sh are skipped.

dns_configured() { return 0; }
dns_update() { return 0; }
