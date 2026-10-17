#!/opt/patroni/bin/python
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fluxer-ha: see docs/architecture.md.
# Renders /etc/patroni.yml with the per-site values Patroni can't take from
# the environment, then execs Patroni (it stays PID 1, as before).
#
#   FLUXER_HA_SITE_WG_IPS   the two SITES' WireGuard addresses, comma-separated.
#                           Each gets a /32 pg_hba entry for replication and
#                           for clients. The witness is deliberately absent: it
#                           runs no Postgres and has no business connecting.
#   FLUXER_HA_PG_HBA_EXTRA  optional extra pg_hba lines, separated by ";", for a
#                           client outside the two sites (the lab's database
#                           writer). Each one widens access; keep them narrow
#                           (one database, one user, one /32).
#
# A rule for the whole mesh subnet would include the witness.
import ipaddress
import os
import sys

import yaml

SRC = '/etc/patroni.yml'
DST = '/tmp/patroni.yml'

with open(SRC) as f:
    cfg = yaml.safe_load(f)

ips = [s.strip() for s in os.environ.get('FLUXER_HA_SITE_WG_IPS', '').split(',') if s.strip()]
if len(ips) != 2:
    sys.exit('entrypoint: FLUXER_HA_SITE_WG_IPS must list exactly the two sites\' WireGuard addresses')
hba = cfg['postgresql']['pg_hba']
for raw in ips:
    ip = ipaddress.ip_address(raw)  # raises on anything that isn't an address
    net = f'{ip}/{ip.max_prefixlen}'
    hba.append(f'host replication replicator {net} scram-sha-256')
    hba.append(f'host all all {net} scram-sha-256')

for line in os.environ.get('FLUXER_HA_PG_HBA_EXTRA', '').split(';'):
    line = ' '.join(line.split())
    if not line:
        continue
    if not line.startswith('host ') or 'trust' in line.split():
        sys.exit(f'entrypoint: refusing FLUXER_HA_PG_HBA_EXTRA line {line!r}: must be a "host" line, never trust')
    hba.append(line)

fd = os.open(DST, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)

os.execv('/opt/patroni/bin/patroni', ['patroni', DST])
