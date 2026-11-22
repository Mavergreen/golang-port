#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/build-builder.sh: one make.bash per build, on any host. Leaves $WORK/go built for the HOST,
#       from the patched source, with the family's C wrapper first on PATH.
#       usage: LINE_ROOT=<line checkout> [GOROOT_BOOTSTRAP=<go>] sh build/build-builder.sh
#       It runs build/c-toolchain.sh itself, and runs fetch-go.sh + apply-patches.sh itself whenever it has to (re)build, because
#       a half-built or differently-patched tree must never be reused. An existing builder whose $WORK/builder.key matches
#       is reused as is. BUILDER_FETCH_GO / BUILDER_APPLY_PATCHES replace those two steps in tests only.
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
. "$PORT_DIR/build/env.sh" || exit $?

CC_WRAPPER="$(sh "$PORT_DIR/build/c-toolchain.sh")" || exit $?
CC_DIR="$(dirname "$CC_WRAPPER")"
clang22="$(sed -n 's/^clang22=//p' "$WORK/cc/versions")"

# spec: PORT.md, the build chain -- the builder key: Go version, sha256 over the line's patches + the port's overlay + apply-overlay.sh
#       (sorted, names and contents), the clang22 version c-toolchain recorded (the installed one, which on a dev box may differ
#       from the pin), and `uname -sm`. The bootstrap toolchain is left OUT of the key on purpose (shipyard ruling): make.bash
#       rebuilds the toolchain in three stages, so its output does not depend on the bootstrap.
patch_sha="$( { ( cd "$LINE_ROOT" && LC_ALL=C find patches -type f -name '*.patch' | LC_ALL=C sort \
      | while read -r f; do printf '%s %s\n' "$(shasum -a 256 < "$f" | awk '{print $1}')" "$f"; done )
    ( cd "$PORT_DIR" && LC_ALL=C find overlay apply-overlay.sh -type f ! -name '._*' ! -name .DS_Store | LC_ALL=C sort \
      | while read -r f; do printf '%s %s\n' "$(shasum -a 256 < "$f" | awk '{print $1}')" "$f"; done ); } \
    | shasum -a 256 | awk '{print $1}')"
{
  echo "go=$GO_VERSION"
  echo "patches=$patch_sha"
  echo "clang22=$clang22"
  echo "host=$(uname -sm)"
} > "$WORK/builder.key.new"

if [ -f "$WORK/builder.key" ] && [ -x "$WORK/go/bin/go" ] && [ -f "$WORK/builder.tools" ] && cmp -s "$WORK/builder.key" "$WORK/builder.key.new"; then
  rm -f "$WORK/builder.key.new"
  echo "build-builder.sh: reusing the builder at $WORK/go (builder.key matches)" >&2
  exit 0
fi

# spec: PORT.md, the build chain -- anything short of a matching key and a built go starts again from a pristine tree; the key returns only after make.bash succeeds.
rm -f "$WORK/builder.key" "$WORK/builder.tools"
sh "${BUILDER_FETCH_GO:-$PORT_DIR/build/fetch-go.sh}"
sh "${BUILDER_APPLY_PATCHES:-$PORT_DIR/build/apply-patches.sh}"

# spec: PORT.md, the build chain -- bootstrap: GOROOT_BOOTSTRAP if given, else the GOROOT of the go on PATH.
if [ -z "${GOROOT_BOOTSTRAP:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "build-builder.sh: no GOROOT_BOOTSTRAP and no go on PATH to bootstrap from" >&2; exit 1; }
  GOROOT_BOOTSTRAP="$(go env GOROOT)"
fi
[ -x "$GOROOT_BOOTSTRAP/bin/go" ] || { echo "build-builder.sh: no bootstrap go at $GOROOT_BOOTSTRAP/bin/go" >&2; exit 1; }
export GOROOT_BOOTSTRAP

# spec: PORT.md, the build chain -- nothing from the caller's environment may steer make.bash: the compiler (zdefaultcc.go bakes CC), the
#       target, and cgo settings all come from the wrapper on PATH and Go's own defaults. Each variable that was set is named.
_unset=""
for v in CC CXX CC_FOR_TARGET CXX_FOR_TARGET GOOS GOARCH GOHOSTOS GOHOSTARCH GOROOT_FINAL GO_LDFLAGS BOOT_GO_LDFLAGS \
         GO_BOOTSTRAP_LDFLAGS GO_EXTLINK_ENABLED \
         GOAMD64 GOARM64 GO386 GOARM GOEXPERIMENT GOFIPS140 GO_LDSO PKG_CONFIG $(env | sed -n 's/^\(CGO_[A-Za-z0-9_]*\)=.*/\1/p'); do
  if [ -n "$(eval "printf %s \"\${$v+set}\"")" ]; then _unset="$_unset $v"; unset "$v"; fi
done
[ -z "$_unset" ] || echo "build-builder.sh: unset$_unset so the build cannot inherit them" >&2

# spec: PORT.md, the build chain -- GO_EXTLINK_ENABLED=darwin/amd64 is baked in as the linker's default by hook patches 0011/0012:
#       darwin/amd64 binaries, pure Go included, external-link through the 10.9 wrapper. The builder's own links are
#       not darwin/amd64, so they are unaffected. GOROOT_FINAL is not set: Go ignores it since 1.21.
export GO_EXTLINK_ENABLED=darwin/amd64
export PATH="$CC_DIR:$PATH"
export GOCACHE="$WORK/.gocache"
( cd "$WORK/go/src" && ./make.bash -v )
[ -x "$WORK/go/bin/go" ] || { echo "build-builder.sh: make.bash left no $WORK/go/bin/go" >&2; exit 1; }
# spec: PORT.md, the build chain -- the tools make.bash installed for the host are Go's own distribution list, the tools every product
#       ships. Recorded now: on a darwin/amd64 host a product's `go install cmd` later adds every other tool in place.
: > "$WORK/builder.tools"
for d in "$WORK/go/pkg/tool"/*; do
  [ -d "$d" ] || continue
  ( cd "$d" && LC_ALL=C ls ) >> "$WORK/builder.tools"
done
mv "$WORK/builder.key.new" "$WORK/builder.key"
echo "build-builder.sh: built $WORK/go (key: $(tr '\n' ' ' < "$WORK/builder.key"))" >&2
