#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/build-updater.sh builds the two Sparkle updaters with clang22 on any host. This reads the built
#       apps back with clang22's llvm-otool (no otool on Linux): the bundle id the line's registry derives, no link to anything the
#       updater updates (it would circle on self-update), and the slice each updater is meant to be: native x86_64 minos 10.9 sdk 10.9,
#       cross arm64 minos 11.0 sdk 11.3. Skips (77) until build-updater.sh has built them (it takes minutes and the network).
here=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "FAIL: $*"; exit 1; }
LINE_ROOT="${LINE_ROOT:-$here/tests/fixtures/line-127}"; export LINE_ROOT
PORT_DIR="$here"; export PORT_DIR
. "$here/build/env.sh" || exit $?
[ -f "$here/build/build-updater.sh" ] || fail "no build/build-updater.sh"
OTOOL="${MAVERGREEN_PREFIX:-/usr/local/mavergreen}/clang22/bin/llvm-otool"
[ -x "$OTOOL" ] || { echo "no $OTOOL -- skipping"; exit 77; }
n="$MAVERICKS_BUILD_ROOT/golang-updater/go$GO_LINE-updater.app"
c="$MAVERICKS_BUILD_ROOT/golang-updater-cross/go$GO_LINE-cross-updater.app"
[ -d "$n" ] || [ -d "$c" ] || { echo "no updater built under $MAVERICKS_BUILD_ROOT (sh build/build-updater.sh native|cross) -- skipping"; exit 77; }

# spec: tests/updater-test.sh -- check_app <app> <short> <arch> <minos> <sdk>
check_app() {
  app=$1; short=$2
  exe=$(ls "$app/Contents/MacOS" 2>/dev/null | sed -n 1p)
  [ -n "$exe" ] || fail "$app has no executable"
  bin="$app/Contents/MacOS/$exe"
  grep -A1 '<key>CFBundleIdentifier</key>' "$app/Contents/Info.plist" | grep -q "<string>dev.mavergreen.golang.$short.updater</string>" \
    || fail "$app: bundle id is not dev.mavergreen.golang.$short.updater"
  "$OTOOL" -L "$bin" > "${TMPDIR:-/tmp}/updater-test.$$" 2>&1 || fail "$app: llvm-otool -L failed"
  if grep -q '/usr/local/mavergreen/' "${TMPDIR:-/tmp}/updater-test.$$"; then
    cat "${TMPDIR:-/tmp}/updater-test.$$"; rm -f "${TMPDIR:-/tmp}/updater-test.$$"
    fail "$app links something under /usr/local/mavergreen/ -- it must not link what it updates"
  fi
  rm -f "${TMPDIR:-/tmp}/updater-test.$$"
  [ -d "$app/Contents/Frameworks/Sparkle.framework" ] || fail "$app does not bundle Sparkle.framework"
  hdr=$("$OTOOL" -hv "$bin" | tr -s ' ' | grep -c "X86_64\|ARM64")
  [ "$hdr" = 1 ] || fail "$app: want exactly one slice, got $hdr"
  "$OTOOL" -hv "$bin" | grep -q "$3" || fail "$app: slice is not $3"
  # spec: tests/updater-test.sh -- an old deployment target is recorded as LC_VERSION_MIN_MACOSX (version/sdk), a new one as LC_BUILD_VERSION (minos/sdk).
  "$OTOOL" -l "$bin" | tr -s ' ' | grep -A4 'cmd LC_BUILD_VERSION\|cmd LC_VERSION_MIN_MACOSX' > "${TMPDIR:-/tmp}/updater-test-l.$$"
  grep -q " \(minos\|version\) $4\$" "${TMPDIR:-/tmp}/updater-test-l.$$" || { rm -f "${TMPDIR:-/tmp}/updater-test-l.$$"; fail "$app: minos is not $4"; }
  grep -q " sdk $5\$" "${TMPDIR:-/tmp}/updater-test-l.$$" || { rm -f "${TMPDIR:-/tmp}/updater-test-l.$$"; fail "$app: sdk is not $5"; }
  rm -f "${TMPDIR:-/tmp}/updater-test-l.$$"
  echo "ok: $app ($3 minos $4 sdk $5)"
}
[ -d "$n" ] && check_app "$n" "go$GO_LINE" X86_64 10.9 10.9
[ -d "$c" ] && check_app "$c" "go$GO_LINE-cross" ARM64 11.0 11.3
echo "PASS: updater"
