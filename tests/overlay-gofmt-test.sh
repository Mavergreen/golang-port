#!/bin/sh
# platform: host-agnostic
here=$(cd "$(dirname "$0")/.." && pwd)
command -v gofmt >/dev/null 2>&1 || exit 77
bad=$(gofmt -l -e "$here/overlay" 2>&1)
if [ -n "$bad" ]; then
  echo "FAIL: gofmt reports these overlay files: $bad -- a syntax error here reaches every line's build"
  exit 1
fi
echo "PASS: overlay is gofmt-clean"
