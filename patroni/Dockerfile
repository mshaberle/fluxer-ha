# SPDX-License-Identifier: AGPL-3.0-or-later
#
# fluxer-ha: see docs/architecture.md.
# Postgres 16 managed by Patroni. Patroni owns promotion, demotion, rejoin and
# synchronous-standby selection.
#
# Supply chain (docs/security.md S9): the base image is pinned by digest (the multi-arch
# index for postgres:16-bookworm, 2026-10-15), and Patroni and its
# dependencies by sha256 (requirements.txt). To upgrade, bump both on purpose.
FROM postgres:16-bookworm@sha256:0ea6700a3b4f0ae6ce746519073558aed4d88a79d8d07622a9a644946c7319c4

COPY requirements.txt /tmp/requirements.txt
RUN apt-get update \
	&& apt-get install -y --no-install-recommends python3 python3-venv curl \
	&& python3 -m venv /opt/patroni \
	&& /opt/patroni/bin/pip install --no-cache-dir --require-hashes --no-deps -r /tmp/requirements.txt \
	&& /opt/patroni/bin/pip uninstall -y -q setuptools \
	&& rm -f /usr/local/bin/gosu \
	&& rm -rf /var/lib/apt/lists/* /tmp/requirements.txt
# Removed after the install, because nothing here uses them at run time and
# the image scanner flags both (docs/security.md S23): setuptools, needed only
# to build the two packages without wheels (ydiff, python-etcd), and gosu, the
# base image's privilege-dropping helper (built with an old Go). This image
# starts as postgres with no-new-privileges, so it never needs gosu.

COPY patroni.yml /etc/patroni.yml
COPY entrypoint.py /usr/local/bin/fluxer-patroni
RUN chmod 755 /usr/local/bin/fluxer-patroni

# The postgres base image sets STOPSIGNAL SIGINT. Patroni shuts down cleanly
# (stops Postgres, releases the leader key) only on SIGTERM. With SIGINT, a
# `docker compose stop` or recreate left the leader holding its key and
# Postgres needing crash recovery (lab).
STOPSIGNAL SIGTERM

USER postgres
# Renders the per-site pg_hba into /tmp/patroni.yml, then execs Patroni.
ENTRYPOINT ["/usr/local/bin/fluxer-patroni"]
