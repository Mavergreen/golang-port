#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/fetch-ca.sh: provides the line's pinned CA bundle at $WORK/ca-certificates.crt and prints that path.
#       usage: LINE_ROOT=<line checkout> sh build/fetch-ca.sh
#       The bundle is VENDORED at $LINE_ROOT/vendor/cacert.pem and used from there, verified against CA_SHA256 (line.env), so
#       builds are reproducible and independent of the network: curl.se serves only the LATEST cacert.pem and rotates it
#       about quarterly, so a download-only pin would become unsatisfiable. To refresh, set CA_SHA256 in line.env to
#       the new bundle's hash and run with MAVERICKS_CA_REFRESH=1: it downloads, verifies and rewrites the line's vendor copy.
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
. "$PORT_DIR/build/env.sh" || exit $?
mkdir -p "$WORK"
out="$WORK/ca-certificates.crt"
vend="$LINE_ROOT/vendor/cacert.pem"

if [ -f "$vend" ] && [ "${MAVERICKS_CA_REFRESH:-0}" != 1 ]; then
  got="$(shasum -a 256 "$vend" | awk '{print $1}')"
  [ "$got" = "$CA_SHA256" ] || { echo "FATAL: vendored CA sha256 mismatch: got $got want $CA_SHA256" >&2; exit 1; }
  grep -q 'ISRG Root X1' "$vend" || { echo "FATAL: vendored bundle missing ISRG Root X1" >&2; exit 1; }
  cp "$vend" "$out"
  echo "$out"
  exit 0
fi

. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
shipyard_curl "$CA_URL" "$out"
got="$(shasum -a 256 "$out" | awk '{print $1}')"
[ "$got" = "$CA_SHA256" ] || { echo "FATAL: CA bundle sha256 mismatch: got $got want $CA_SHA256 (update CA_SHA256 in line.env to refresh)" >&2; exit 1; }
grep -q 'ISRG Root X1' "$out" || { echo "FATAL: bundle missing ISRG Root X1" >&2; exit 1; }
mkdir -p "$LINE_ROOT/vendor"
cp "$out" "$vend"   # keep the line's vendored copy in sync
echo "$out"
