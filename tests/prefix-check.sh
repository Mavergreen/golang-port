#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- fixed C-toolchain paths. Every prefix is derived from the line (/usr/local/mavergreen/go${GO_LINE}),
#       so this asserts the derived VALUES for each line the port has a fixture for, not the spelling of any source line; and that no
#       tracked file of the port still names a prefix the family has left.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
PORT_DIR="$(cd "$here/.." && pwd)"
export PORT_DIR
fail=0
n=0
for fx in "$here"/fixtures/line-*; do
  [ -d "$fx" ] || continue
  n=$((n + 1))
  out="$(LINE_ROOT="$fx" sh -c '. "$PORT_DIR/build/env.sh" && printf "%s\n%s\n%s\n%s\n" "$GO_LINE" "$PREFIX" "$CROSS_PREFIX" "$CA_DIR"')" \
    || { echo "FAIL: env.sh does not source for $fx"; fail=1; continue; }
  line="$(printf '%s\n' "$out" | sed -n 1p)"
  prefix="$(printf '%s\n' "$out" | sed -n 2p)"
  cross="$(printf '%s\n' "$out" | sed -n 3p)"
  ca="$(printf '%s\n' "$out" | sed -n 4p)"
  [ "$prefix" = "/usr/local/mavergreen/go$line" ] \
    || { echo "FAIL: line $line: PREFIX is '$prefix', expected the product tree /usr/local/mavergreen/go$line"; fail=1; }
  [ "$cross" = "/usr/local/mavergreen/go$line-cross" ] \
    || { echo "FAIL: line $line: CROSS_PREFIX is '$cross', expected /usr/local/mavergreen/go$line-cross"; fail=1; }
  [ "$ca" = "/usr/local/mavergreen/go$line/etc/openssl" ] \
    || { echo "FAIL: line $line: CA_DIR is compiled into every program either toolchain builds, so it must be inside the native tree: got '$ca'"; fail=1; }
done
[ "$n" -gt 0 ] || { echo "FAIL: no tests/fixtures/line-* to derive prefixes from"; exit 1; }

# spec: PORT.md, the build chain -- the old prefixes: /usr/local/mavericks-go (before the family rename) and /usr/local/go1NN (before products had trees of their own)
cd "$PORT_DIR"
for f in $(git ls-files build CMakeLists.txt .github resources updater overlay PORT.md INGREDIENTS.md 'release-notes/*.md'); do
  if grep -En '/usr/local/mavericks-go|/usr/local/go1[0-9][0-9]' "$f" >/dev/null 2>&1; then
    echo "FAIL: an old prefix is still named in $f:"; grep -En '/usr/local/mavericks-go|/usr/local/go1[0-9][0-9]' "$f"; fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
echo "prefix-check OK"
