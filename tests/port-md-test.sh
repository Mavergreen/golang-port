#!/bin/sh
# platform: host-agnostic
# spec: PORT.md is the authority on why each carried change exists
# usage: sh tests/port-md-test.sh   (PORT_ROOT=<dir> to check a copy of the port)
set -eu
R="${PORT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
M="$R/PORT.md"
[ -f "$M" ] || { echo "FAIL: no PORT.md -- every carried change needs its reason tracked"; exit 1; }
fail=0
# spec: PORT.md -- one section per overlay file, and no section for a missing file
for f in $(cd "$R" && find overlay -type f ! -name '._*' ! -name .DS_Store | sort); do
  grep -q "^### $f\$" "$M" || { echo "FAIL: PORT.md has no '### $f' section"; fail=1; }
done
for f in $(sed -n 's|^### \(overlay/.*\)$|\1|p' "$M"); do
  [ -f "$R/$f" ] || { echo "FAIL: PORT.md explains $f, which is not in the overlay"; fail=1; }
done
# spec: PORT.md -- one section per port patch (a line's hook patches are held to PORT.md by that line's own port-md-test)
for f in $(cd "$R" && find patches -type f -name '*.patch' 2>/dev/null | sed 's|^patches/||' | sort); do
  grep -q "^### $f\$" "$M" || { echo "FAIL: PORT.md has no '### $f' section"; fail=1; }
done
# spec: PORT.md "Build chain" -- one entry per Phase 0 rule, plus the standing rules and known differences
grep -q "^## Build chain\$" "$M" || { echo "FAIL: PORT.md has no '## Build chain' section"; fail=1; }
for h in "-trimpath on every toolchain binary" "Fixed C-toolchain paths" "CC and CC_FOR_TARGET are unset during make.bash" "DWARF is kept: dsymutil and strip come from clang22" "Standing rules and known differences"; do
  grep -qF "### $h" "$M" || { echo "FAIL: PORT.md's Build chain has no '### $h' entry"; fail=1; }
done
# spec: decision 4 -- every carried change in PORT.md has a Reconsider line
awk '
  /^### / { if (name != "") report(); name = $0; has = 0; next }
  /^## / { if (name != "") report(); name = ""; next }
  name != "" && /Reconsider/ { has = 1 }
  END { if (name != "") report(); if (bad) exit 1 }
  function report() { if (!has) { print "FAIL: " name " has no *Reconsider* line -- every carried change says when to reconsider it (spec decision 4)"; bad = 1 } }
' "$M" || fail=1
# spec: PORT.md "Hook ↔ overlay interface" -- each name in its table must still be defined in the overlay
names=$(awk '
  /^## / { in_iface = ($0 == "## Hook ↔ overlay interface"); next }
  in_iface && /^\|/ { n = split($0, col, "|"); print col[3] }
' "$M" | grep -o '`keychainUnion[A-Za-z]*`' | tr -d '`' | sort -u)
[ -n "$names" ] || { echo "FAIL: PORT.md's interface table names no keychainUnion identifiers"; fail=1; }
for n in $names; do
  if ! find "$R/overlay" -name '*.go' ! -name '*_test.go' -exec grep -lE "^(func $n\(|var $n([^A-Za-z0-9_]|\$))" {} + >/dev/null 2>&1; then
    echo "FAIL: PORT.md's interface table names $n, which the overlay no longer defines -- a line's hook calls it, so renaming it is a major bump (PORT.md)"
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
echo "PASS: port-md"
