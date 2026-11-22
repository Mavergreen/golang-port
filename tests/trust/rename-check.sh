#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- the family dropped "pkgsrc" from this tree's names; nothing the port ships may bring it back.
set -eu
cd "$(dirname "$0")/../.."
fail=0
# spec: PORT.md, the build chain -- 'test' never existed -- a grep aimed at a missing directory checks nothing while still looking like a guard.
scan="overlay build tests updater resources"
if grep -ril pkgsrc $scan 2>/dev/null | grep -v rename-check.sh | grep -q .; then
  echo "FAIL: 'pkgsrc' still present:"; grep -ril pkgsrc $scan | grep -v rename-check.sh
  fail=1
fi
[ -f build/extract-patches.sh ] && { echo "FAIL: extract-patches.sh is back"; fail=1; }
[ "$fail" = 0 ] && echo "rename-check OK"
exit $fail
