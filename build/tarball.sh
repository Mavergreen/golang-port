#!/bin/sh
# platform: host-agnostic
# usage: sh build/tarball.sh <outdir>
set -eu

die() { code=$1; shift; echo "tarball.sh: $*" >&2; exit "$code"; }

[ $# -eq 1 ] || die 2 "usage: sh build/tarball.sh <outdir>"
out=$1
root=$(cd "$(dirname "$0")/.." && pwd)

v=$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")
case "$v" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die 2 "UPSTREAM_VERSION '$v' is not x.y.z" ;;
esac
case "$v" in
  *[!0-9.]*|.*|*.|*..*|*.*.*.*) die 2 "UPSTREAM_VERSION '$v' is not x.y.z" ;;
esac

mkdir -p "$out"
out=$(cd "$out" && pwd)
# spec: PORT.md, the build chain -- the tarball carries the whole port: the overlay and the build chain a line runs (build/, CMakeLists.txt,
#       updater/, resources/, tests/). tests/fixtures/line-* are copies of what a line holds, so they stay out. gzip -n and git archive's
#       fixed mtimes keep it reproducible.
git -C "$root" archive --format=tar --prefix="golang-port-$v/" HEAD \
  LICENSE PORT.md UPSTREAM_VERSION apply-overlay.sh overlay build CMakeLists.txt updater resources tests ':(exclude)tests/fixtures/line-*' | gzip -n > "$out/golang-port-$v.tar.gz"
echo "tarball.sh: $out/golang-port-$v.tar.gz"
