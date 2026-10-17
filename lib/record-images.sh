# SPDX-License-Identifier: AGPL-3.0-or-later
# shellcheck shell=sh
#
# record_images <dir>: what this site's containers run, for `fluxer-ha
# rollback`. Writes <dir>/images, one line per image reference:
#   <reference> <image ID or -> <registry digest or ->
# (install.sh's records have the first two columns), and <dir>/image-tag.
# Run from the Fluxer directory.
# With Docker's containerd image store (the default since Docker 29), an
# image's ID is its registry digest, and moving a tag (a pull, a build) drops
# the old image's local entry at once: `<repository>@<old ID>` is how to get
# it back. With the classic store the old image stays, dangling, with its
# RepoDigests. image_digest <reference> <ID> prints the pullable form, or -.
containerd_store() { docker info -f '{{range .DriverStatus}}{{.}}{{end}}' 2>/dev/null | grep -q containerd.snapshotter; }
image_digest() {
	d=$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$2" 2>/dev/null | grep "^${1%%[:@]*}@" | head -n 1)
	[ -n "$d" ] || ! containerd_store || d=${1%%[:@]*}@$2
	echo "${d:--}"
}

record_images() {
	mkdir -p "$1" && chmod 700 "$1"
	case $1 in fluxer-ha/upgrade/*) chmod 700 fluxer-ha/upgrade ;; esac
	sed -n 's/^FLUXER_IMAGE_TAG=//p' .env | tail -n 1 >"$1/image-tag"
	docker compose --profile app config --format json |
		jq -r '.services | to_entries[] | "\(.key) \(.value.image // "-")"' |
		while read -r svc ref; do
			[ "$ref" != - ] || continue
			cid=$(docker compose --profile app ps -aq "$svc" 2>/dev/null | head -n 1)
			id=-; [ -z "$cid" ] || id=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || echo -)
			dig=-; [ "$id" = - ] || dig=$(image_digest "$ref" "$id")
			printf '%s %s %s\n' "$ref" "$id" "$dig"
		done | sort -u >"$1/images"
}
