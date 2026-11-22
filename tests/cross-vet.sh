#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- the fast fail that stays in the build job: the patched crypto/x509 must vet and compile its tests for
#       darwin/amd64 from any host, with the toolchain the build produced. Without a built toolchain there is nothing to check: exit 77.
#       usage: sh tests/cross-vet.sh            LINE_ROOT=<line checkout> finds the builder's $WORK/go (what make.bash built, patched)
#              CROSS_VET_GOROOT=<goroot> sh tests/cross-vet.sh      any built Go tree
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
goroot="${CROSS_VET_GOROOT:-}"
if [ -z "$goroot" ] && [ -n "${LINE_ROOT:-}" ]; then
  PORT_DIR="$(cd "$here/.." && pwd)"; export PORT_DIR
  goroot="$(. "$PORT_DIR/build/env.sh" >/dev/null && printf '%s' "$WORK/go")" || { echo "env.sh failed for $LINE_ROOT" >&2; exit 1; }
fi
[ -n "$goroot" ] && [ -x "$goroot/bin/go" ] || { echo "no built toolchain (set CROSS_VET_GOROOT, or LINE_ROOT and run build-builder.sh) -- skipping"; exit 77; }
# spec: PORT.md, the build chain -- make.bash baked CC=clang, and darwin/amd64 links externally (hook patches 0011/0012), so the link finds the build
#       wrapper on PATH: the builder's $WORK/cc/bin, beside its go/ (a shipped toolchain's go.env names its own wrapper instead).
ccdir="$(cd "$goroot/.." && pwd)/cc/bin"
[ -x "$ccdir/clang" ] && PATH="$ccdir:$PATH"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cross-vet.XXXXXX")" || exit 1
[ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
unset CC CXX CGO_ENABLED GOFLAGS GO_EXTLINK_ENABLED
export GOROOT="$goroot" PATH="$goroot/bin:$PATH" GOCACHE="$tmp/gocache" GOENV=off GOTOOLCHAIN=local GOPROXY=off GOOS=darwin GOARCH=amd64
go vet crypto/x509 || { echo "FAIL: GOOS=darwin GOARCH=amd64 go vet crypto/x509"; exit 1; }
go test -c -o /dev/null crypto/x509 || { echo "FAIL: GOOS=darwin GOARCH=amd64 go test -c crypto/x509"; exit 1; }
echo "PASS: cross-vet"
