#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- the cross toolchain ships no SDK fetcher: sdk109 (Longboat's, or install@v1 products: on Linux) holds the SDK,
#       and the toolchain's wrappers name it by path.
set -eu
R="$(cd "$(dirname "$0")/.." && pwd)"
why="the cross toolchain ships no SDK fetcher, because Longboat's sdk109 holds the SDK (sudo longboat sdk install 10.9)"
for f in build/build-cross.sh build/build-linux-cross.sh build/write-wrappers.sh build/cc-wrapper.sh build/package.sh; do
  if grep -n 'libexec' "$R/$f"; then echo "FAIL: $f stages something into libexec/; $why"; exit 1; fi
  for s in fetch_sdk.sh sdk-pins.sh mavericks_fetch.sh; do
    if grep -n "$s" "$R/$f"; then echo "FAIL: $f names $s; $why"; exit 1; fi
  done
done
echo "PASS: no-sdk-fetcher"
