#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, Fixed C-toolchain paths -- darwin/amd64 bytes must not depend on where $WORK is or how it is spelled. The builder is reached
#       twice through build/env.sh and tl_go_env (what build-native.sh uses): once at $WORK, once through a symlink spelled with a
#       doubled slash, a ./ part and a trailing slash. Each builds runtime/cgo and a cgo program with its own GOCACHE; the build IDs
#       must match. Without a built builder there is nothing to build: exit 77.
#       usage: LINE_ROOT=<line checkout> sh tests/work-path-test.sh     (after build/build-builder.sh)
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${LINE_ROOT:-}" ] || { echo "skip: no LINE_ROOT, so no builder to find (set LINE_ROOT and run build/build-builder.sh)"; exit 77; }
work="$(PORT_DIR="$here"; export PORT_DIR; . "$here/build/env.sh" >/dev/null && printf '%s' "$WORK")" || { echo "FAIL: env.sh failed for $LINE_ROOT"; exit 1; }
[ -x "$work/go/bin/go" ] && [ -x "$work/cc/bin/clang" ] || { echo "skip: no built builder at $work (run build/build-builder.sh) -- skipping"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/work-path-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

mkdir "$t/hello"
cp "$here/tests/hello-cgo/main.go" "$t/hello/main.go"
printf 'module hello\n\ngo 1.21\n' > "$t/hello/go.mod"
ln -s "$work" "$t/alias"

# spec: tests/work-path-test.sh -- ids <MAVERICKS_WORK> <n>: prints runtime/cgo's build ID and the cgo program's, built from that WORK
ids() {
  (
    PORT_DIR="$here"; MAVERICKS_WORK="$1"; TL_NAME=work-path-test.sh; export PORT_DIR MAVERICKS_WORK
    . "$here/build/env.sh" >/dev/null || exit 1
    . "$here/build/toolchain-lib.sh"
    tl_go_env 2>/dev/null
    GOCACHE="$t/cache$2" GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 CC=clang
    export GOCACHE GOOS GOARCH CGO_ENABLED CC
    "$GOROOT/bin/go" list -trimpath -export -f '{{.BuildID}}' runtime/cgo || exit 1
    cd "$t/hello" && "$GOROOT/bin/go" build -trimpath -ldflags=-linkmode=external -o "$t/hello$2" . 2>"$t/link$2" \
      || { cat "$t/link$2" >&2; exit 1; }
    "$GOROOT/bin/go" tool buildid "$t/hello$2"
  )
}

a=$(ids "$work" 1) || fail "building from $work"
b=$(ids "$t//alias/./" 2) || fail "building from $t//alias/./"
[ "$a" = "$b" ] || fail "the build IDs depend on the WORK path:
  $work:
$a
  $t//alias/./:
$b"
echo "PASS: work-path ($(echo "$a" | tr '\n' ' '))"
