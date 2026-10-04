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
git -C "$root" archive --format=tar --prefix="golang-port-$v/" HEAD \
  LICENSE PORT.md apply-overlay.sh overlay | gzip -n > "$out/golang-port-$v.tar.gz"
echo "tarball.sh: $out/golang-port-$v.tar.gz"
