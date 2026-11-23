#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/build-native.sh: the darwin/amd64 toolchain (product go1NN), from the host's builder, the same
#       bytes on every host. usage: LINE_ROOT=<line checkout> [GOROOT_BOOTSTRAP=<go>] sh build/build-native.sh
#       Leaves $WORK/staging$PREFIX and prints that path. Runs build-builder.sh itself (which reuses a matching builder).
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
. "$PORT_DIR/build/env.sh" || exit $?
TL_NAME=build-native.sh
sh "$PORT_DIR/build/build-builder.sh"
. "$PORT_DIR/build/toolchain-lib.sh"
CA="$(sh "$PORT_DIR/build/fetch-ca.sh" | tail -1)"
[ -f "$CA" ] || tl_die "fetch-ca.sh produced no CA bundle ($CA)"
RECAULK_LIB="$(tl_cc_var recaulk)"

# spec: PORT.md, the build chain -- the toolchain's own binaries. -trimpath keeps the build host's paths out of them; CC=clang finds the
#       build wrapper on PATH, the same name on every host. -linkmode=external is required: Go internal-links pure-Go binaries on
#       darwin and stamps its own floor (macOS 12+), which no -mmacosx-version-min can undo; external linking sends every binary
#       through the wrapper, so all get minos 10.9 and Recaulk. On a darwin/amd64 host `go install` replaces the builder's own
#       bin/ and pkg/tool binaries in place (with the same Go version, so later builds are unaffected); elsewhere it writes
#       bin/darwin_amd64 and pkg/tool/darwin_amd64. -a relinks every binary every time: the link's dsymutil and strip are not in
#       Go's action IDs, so an installed binary would look up to date after either changed (on 10.9, after Apple's strip had made it).
tl_go_env
GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 CC=clang
export GOOS GOARCH CGO_ENABLED CC
( cd "$WORK/go/src" && "$WORK/go/bin/go" install -a -trimpath -ldflags=-linkmode=external cmd )

stage="$WORK/staging"
dest="$stage$PREFIX"
rm -rf "$stage"
tl_stage darwin amd64 "$dest"
mkdir -p "$dest/etc/openssl/certs" "$dest/lib"
cp "$CA" "$dest/etc/openssl/certs/ca-certificates.crt"
cp "$RECAULK_LIB" "$dest/lib/librecaulk.a"
sh "$PORT_DIR/build/write-wrappers.sh" native "$dest"
# spec: PORT.md, the build chain -- a plain `go build` on the box links 10.9-safe cgo through the shipped wrapper. CC is relative to
#       GOROOT (port patch 0020 resolves it), so the toolchain works wherever it is installed, copied or unpacked.
{
  echo "CGO_ENABLED=1"
  echo "CC=bin/mavericks-clang"
} >> "$dest/go.env"

# spec: PORT.md, the build chain -- every staged binary is an x86_64 Mach-O recording minos 10.9 and sdk 10.9 (a host binary, or one
#       that internal-linked, fails here); the shipped Recaulk has an x86_64 slice.
set --
for f in "$dest"/bin/* "$dest"/pkg/tool/darwin_amd64/*; do
  [ "$f" = "$dest/bin/mavericks-clang" ] || set -- "$@" "$f"
done
tl_macho x86_64 "$MACOS_MIN" "$MACOS_MIN" "$@"
_cl="$(tl_cc_var cc_prefix)"
case " $("$_cl/bin/llvm-lipo" -info "$dest/lib/librecaulk.a" 2>/dev/null | sed -n 's/.*: //p') " in
  *" x86_64 "*) ;;
  *) tl_die "$dest/lib/librecaulk.a has no x86_64 slice" ;;
esac
echo "$dest"
