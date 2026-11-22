#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- Print the official SHA256 of go<version>.src.tar.gz from go.dev's release feed.
#       Set GO_DL_JSON to a local feed file to skip the network (tests, or a caller that
#       already fetched it). No in-repo pin: the feed is the source of truth.
set -eu
VER="${1:?usage: go-src-sha256.sh <go-version, e.g. 1.27.1>}"
file="go${VER}.src.tar.gz"

if [ -n "${GO_DL_JSON:-}" ]; then
  feed="$GO_DL_JSON"
else
  feed="$(mktemp "${TMPDIR:-/tmp}/go-src-sha256.XXXXXX")"   # template: 10.9 BSD mktemp requires one
  trap 'rm -f "$feed"' EXIT
  PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  . "$PORT_DIR/build/msc.sh"
  . "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
  shipyard_curl 'https://go.dev/dl/?mode=json&include=all' "$feed"
fi

# spec: PORT.md, the build chain -- no python3 on the family's hosts: split the feed at braces and commas into one
#       "key": value pair per line, then take the sha256 that follows the matching filename within its file object.
sum="$(tr '{},' '\n\n\n' < "$feed" | awk -v want="$file" '
  /"filename"/ { v = $0; sub(/^[^:]*:[ \t]*"/, "", v); sub(/".*$/, "", v); hit = (v == want); next }
  hit && /"sha256"/ { v = $0; sub(/^[^:]*:[ \t]*"/, "", v); sub(/".*$/, "", v); print v; exit }
')"
[ -n "$sum" ] || { echo "FATAL: $file not found in go.dev feed" >&2; exit 1; }
printf '%s\n' "$sum"
