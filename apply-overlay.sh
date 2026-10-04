#!/bin/sh
# platform: host-agnostic
# usage: sh apply-overlay.sh <goroot> <ssldir>
set -eu

die() { code=$1; shift; echo "apply-overlay.sh: $*" >&2; exit "$code"; }

[ $# -eq 2 ] || die 2 "usage: sh apply-overlay.sh <goroot> <ssldir>"
goroot=$1
ssldir=$2

case $ssldir in
  /*) ;;
  *) die 2 "ssldir '$ssldir' must be an absolute path" ;;
esac
case $ssldir in
  *'#'*|*'&'*) die 2 "ssldir '$ssldir' must not contain '#' or '&' (they would corrupt the substitution)" ;;
esac
[ -f "$goroot/src/crypto/x509/root.go" ] \
  || die 2 "goroot '$goroot' has no src/crypto/x509/root.go -- not a Go source tree"

here=$(cd "$(dirname "$0")" && pwd)
ovl=$here/overlay
[ -d "$ovl" ] || die 1 "no overlay directory at $ovl"
files=$(cd "$ovl" && find . -type f ! -name '._*' ! -name .DS_Store | sed 's#^\./##' | sort)
[ -n "$files" ] || die 1 "overlay at $ovl holds no files; nothing was copied"

found=0
for f in $files; do
  if [ -e "$goroot/$f" ]; then
    die 1 "$goroot/$f already exists: upstream now ships a file of that name, so the overlay must be reworked; nothing was copied"
  fi
  if grep '@SSLDIR@' "$ovl/$f" >/dev/null; then found=1; fi
done
[ "$found" = 1 ] || die 1 "substituted nothing: no overlay file contains @SSLDIR@, so this port is not the one the line expects; nothing was copied"

for f in $files; do
  mkdir -p "$(dirname "$goroot/$f")"
  cp -p "$ovl/$f" "$goroot/$f"
  if grep '@SSLDIR@' "$goroot/$f" >/dev/null; then
    cp -p "$goroot/$f" "$goroot/$f.tmp"
    sed "s#@SSLDIR@#$ssldir#g" "$ovl/$f" > "$goroot/$f.tmp"
    mv "$goroot/$f.tmp" "$goroot/$f"
  fi
done

echo "golang-port: overlay applied to $goroot (@SSLDIR@ -> $ssldir)" >&2
