#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- a maintainer test (tests/maintainer-tests), run by hand: two stagings of one product from the same
#       line, built on two hosts (Linux and the 10.9 box), must have no differences at all under shipyard's build-equivalence.sh.
#       usage: CROSS_HOST_A=<staging dir> CROSS_HOST_B=<staging dir> sh tests/cross-host-bytes.sh
#       (a staging dir is build-native.sh's $WORK/staging or build-cross.sh's $WORK/staging-cross). Skips (77) without both.
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${CROSS_HOST_A:-}" ] && [ -n "${CROSS_HOST_B:-}" ] || { echo "set CROSS_HOST_A and CROSS_HOST_B to two hosts' stagings -- skipping"; exit 77; }
be="${SHIPYARD_SCRIPTS:-}/build-equivalence.sh"
[ -f "$be" ] || { echo "no build-equivalence.sh in SHIPYARD_SCRIPTS (${SHIPYARD_SCRIPTS:-unset}) -- skipping"; exit 77; }
for d in "$CROSS_HOST_A" "$CROSS_HOST_B"; do
  [ -d "$d/usr/local/mavergreen" ] || { echo "FAIL: $d is not a staging (no usr/local/mavergreen)"; exit 1; }
done
t=$(mktemp -d "${TMPDIR:-/tmp}/cross-host-bytes.XXXXXX") || exit 1
trap 'rm -rf "$t"' EXIT
rc=0
sh "$be" --repo "$here" "$CROSS_HOST_A" "$CROSS_HOST_B" > "$t/out" 2> "$t/err" || rc=$?
cat "$t/out" "$t/err"
[ "$rc" = 0 ] || { echo "FAIL: build-equivalence.sh exit $rc"; exit 1; }
[ ! -s "$t/out" ] || { echo "FAIL: the two hosts' stagings differ"; exit 1; }
echo "PASS: cross-host-bytes"
