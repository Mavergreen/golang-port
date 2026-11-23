#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/build-cross.sh: the darwin/arm64-hosted toolchain that emits 10.9 darwin/amd64 programs
#       (product go1NN-cross), from the host's builder, the same bytes on every host.
#       usage: LINE_ROOT=<line checkout> [GOROOT_BOOTSTRAP=<go>] sh build/build-cross.sh
#       Leaves $WORK/staging-cross$CROSS_PREFIX and prints that path. Runs build-builder.sh itself (which reuses a matching builder).
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
. "$PORT_DIR/build/env.sh" || exit $?
TL_NAME=build-cross.sh
sh "$PORT_DIR/build/build-builder.sh"
. "$PORT_DIR/build/toolchain-lib.sh"
RECAULK_LIB="$(tl_cc_var recaulk)"

# spec: PORT.md, the build chain -- the arm64 tools need no Darwin linker: with cgo off, Go internal-links them (Phase 0 spike 3), and
#       they record Go's own minos and sdk. -trimpath keeps the build host's paths out. The darwin/amd64 programs they emit
#       external-link through mavericks-cross-clang (GO_EXTLINK_ENABLED, baked into the builder).
tl_go_env
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0
export GOOS GOARCH CGO_ENABLED
( cd "$WORK/go/src" && "$WORK/go/bin/go" install -trimpath cmd )

stage="$WORK/staging-cross"
dest="$stage$CROSS_PREFIX"
rm -rf "$stage"
tl_stage darwin arm64 "$dest"
mkdir -p "$dest/lib"
cp "$RECAULK_LIB" "$dest/lib/librecaulk.a"
# spec: PORT.md, the build chain -- the cross pkg requires sdk109; this link names it at its installed place, beside the cross prefix.
ln -s ../sdk109/SDKs "$dest/SDKs"
sh "$PORT_DIR/build/write-wrappers.sh" cross "$dest"
# spec: PORT.md, the build chain -- out of the box the cross toolchain targets 10.9 darwin/amd64; the wrapper handles the link. CC is
#       relative to GOROOT (port patch 0020 resolves it), so the toolchain works wherever it is installed, copied or unpacked.
{
  echo "GOOS=darwin"
  echo "GOARCH=amd64"
  echo "CGO_ENABLED=1"
  echo "CC=bin/mavericks-cross-clang"
} >> "$dest/go.env"

# spec: PORT.md, the build chain -- every staged binary is an arm64 Mach-O (a host binary fails here); its minos and sdk are Go's
#       own stamp, reported, not checked (the line's CROSS_MIN_OS is the pkg's install floor).
set --
for f in "$dest"/bin/* "$dest"/pkg/tool/darwin_arm64/*; do
  [ "$f" = "$dest/bin/mavericks-cross-clang" ] || set -- "$@" "$f"
done
tl_macho arm64 "" "" "$@"
echo "$dest"
