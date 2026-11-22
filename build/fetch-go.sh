#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/fetch-go.sh: leaves a pristine, verified Go source tree at $WORK/go.
#       usage: LINE_ROOT=<line checkout> sh build/fetch-go.sh
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
. "$PORT_DIR/build/env.sh" || exit $?
GO_SRC_URL="https://go.dev/dl/go${GO_VERSION}.src.tar.gz"
mkdir -p "$WORK"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
tarball="$WORK/go${GO_VERSION}.src.tar.gz"
[ -f "$tarball" ] || shipyard_curl "$GO_SRC_URL" "$tarball"

# spec: PORT.md, the build chain -- verify against go.dev's OWN published SHA256 (fetched fresh; not pinned in-repo), so a version bump
#       is self-contained -- there is no committed hash to keep in sync.
want="$(sh "$PORT_DIR/build/go-src-sha256.sh" "$GO_VERSION")" || exit $?
[ -n "$want" ] || { echo "FATAL: no sha256 for go${GO_VERSION} in go.dev feed" >&2; exit 1; }
got="$(shasum -a 256 "$tarball" | awk '{print $1}')"
[ "$got" = "$want" ] || { echo "FATAL: go src SHA256 mismatch: got $got want $want" >&2; exit 1; }

rm -rf "$WORK/go"
tar -C "$WORK" -xzf "$tarball"
[ -f "$WORK/go/src/make.bash" ] || { echo "FATAL: unexpected archive layout" >&2; exit 1; }
echo "fetched + verified go${GO_VERSION} (sha256 $got) -> $WORK/go"
