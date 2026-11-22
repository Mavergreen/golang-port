#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/package.sh packages the staged native and cross toolchains through shipyard's seams, which run
#       on any host through stevedore. This reads the two .pkg files back with stevedore, never with pkgutil, so it runs wherever
#       package.sh does. Needs shipyard (stage_product.sh) and a stevedore it can fetch; without either it skips (77).
here=$(cd "$(dirname "$0")/.." && pwd)
# spec: tests/fixtures/line-* are copies of what a line holds and stay out of the tarball, so this test skips there
ls -d "$here"/tests/fixtures/line-* >/dev/null 2>&1 || { echo "skip: no tests/fixtures/line-* (run from the tarball); this test needs the line fixtures"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/package-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT
t=$(cd "$t" && pwd)
fail() { echo "FAIL: $*"; exit 1; }

if [ -z "${SHIPYARD_SCRIPTS:-}" ]; then
  # shellcheck disable=SC1091
  SHIPYARD_SCRIPTS=$(. "$here/build/msc.sh" >/dev/null 2>&1 && echo "$SHIPYARD_SCRIPTS")
fi
[ -f "${SHIPYARD_SCRIPTS:-/nonexistent}/stage_product.sh" ] || { echo "no shipyard with stage_product.sh -- skipping"; exit 77; }
export SHIPYARD_SCRIPTS
sd=$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh" 2>"$t/sd.err") || { cat "$t/sd.err"; echo "no stevedore -- skipping"; exit 77; }

fx="$here/tests/fixtures/line-127"
LINE_ROOT="$fx"; MAVERICKS_WORK="$t/work"; SOURCE_DATE_EPOCH=1700000000; UPD_APP="$t/no-updater.app"
export LINE_ROOT MAVERICKS_WORK SOURCE_DATE_EPOCH UPD_APP
unset MAVERICKS_ROOT
PORT_DIR="$here"; export PORT_DIR
. "$here/build/env.sh" || exit $?

mk() { mkdir -p "${1%/*}"; printf '#!/bin/sh\n' > "$1"; chmod 755 "$1"; }
n="$WORK/staging$PREFIX"; c="$WORK/staging-cross$CROSS_PREFIX"
for f in bin/go bin/gofmt bin/mavericks-clang; do mk "$n/$f"; done
mkdir -p "$n/etc/openssl/certs"; : > "$n/etc/openssl/certs/ca-certificates.crt"; echo license > "$n/LICENSE"
for f in bin/go bin/gofmt bin/mavericks-cross-clang; do mk "$c/$f"; done
ln -s ../sdk109/SDKs "$c/SDKs"
: > "$n/._AppleDouble"
mkdir -p "$WORK/cc"
printf 'clang22=22.1.8-mavericks.99\nrecaulk=20261122.3\nsdk109=20261012.2\npins=lenient\n' > "$WORK/cc/versions"

# spec: build/package.sh -- both pkgs build from a staged tree and print their paths
sh "$here/build/package.sh" native > "$t/native.out" 2> "$t/native.err" || { cat "$t/native.err"; fail "native must package from a staged tree"; }
sh "$here/build/package.sh" cross > "$t/cross.out" 2> "$t/cross.err" || { cat "$t/cross.err"; fail "cross must package from a staged tree"; }
base="${PKG_VERSION#*-}"
np="$WORK/out/golang-$GO_VERSION-native-$base.pkg"; xp="$WORK/out/golang-$GO_VERSION-cross-$base.pkg"
[ -f "$np" ] && [ -f "$xp" ] || fail "want $np and $xp"
[ "$(tail -1 "$t/native.out")" = "$np" ] || fail "native prints its pkg path last, got: $(tail -1 "$t/native.out")"
[ "$(tail -1 "$t/cross.out")" = "$xp" ] || fail "cross prints its pkg path last"
echo "ok: both packages built"

# spec: build/package.sh -- the staging is left as build-native.sh made it (the manifest is written into a copy)
[ ! -e "$n/mavergreen.plist" ] && [ ! -e "$WORK/staging/usr/local/mavergreen/go$GO_LINE/mavergreen.plist" ] || fail "package.sh wrote into the staging"

expand() { "$sd" expand "$1" "$2" > /dev/null 2>&1 || fail "stevedore cannot expand $1"; }
payload() { # payload PKGDIR DEST: unpack every component's payload
  mkdir -p "$2"
  for comp in "$1"/*.pkg; do (cd "$2" && gzip -dc "$comp/Payload" | cpio -id --quiet 2>/dev/null); done
}
expand "$np" "$t/xn"; expand "$xp" "$t/xx"
payload "$t/xn" "$t/vn"; payload "$t/xx" "$t/vx"

for p in xn xx; do
  first=$(sed -n 's/.*<line choice="\([^"]*\)".*/\1/p' "$t/$p/Distribution" | grep -v '^default$' | sed -n 1p)
  [ "$first" = dev.mavergreen.base ] || fail "$p: dev.mavergreen.base is the first component, got '$first'"
done
echo "ok: dev.mavergreen.base first"

# spec: build/package.sh -- the manifests: product, group go, line
mf() { echo "$t/$1/usr/local/mavergreen/$2/mavergreen.plist"; }
get() { "$sd" plist get "$(mf "$1" "$2")" "$3"; }
[ "$(get vn go$GO_LINE product)" = go$GO_LINE ] || fail "native manifest product"
[ "$(get vn go$GO_LINE group)" = go ] || fail "native manifest group"
[ "$(get vn go$GO_LINE line)" = $GO_LINE ] || fail "native manifest line"
[ "$(get vx go$GO_LINE-cross product)" = go$GO_LINE-cross ] || fail "cross manifest product"
[ "$(get vx go$GO_LINE-cross group)" = go ] || fail "cross manifest group"
[ "$(get vx go$GO_LINE-cross line)" = $GO_LINE-cross ] || fail "cross manifest line"
echo "ok: manifests"

# spec: build/package.sh -- Ruling F: the shipped wrappers call clang22, so the native pkg requires clang22 and the cross pkg
#       clang22-cross (the cross pkg also needs longboat >= 20261019.1 for the SDK, and sdk109)
reqs() { sed -n '/<key>requires<\/key>/,/<\/array>/p' "$(mf "$1" "$2")" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | sed 's/&gt;/>/g'; }
reqs vn go$GO_LINE > "$t/rn"; reqs vx go$GO_LINE-cross > "$t/rx"
grep -qx 'clang22' "$t/rn" || fail "native pkg must require clang22, requires: $(tr '\n' ' ' < "$t/rn")"
grep -qx 'clang22-cross' "$t/rx" || fail "cross pkg must require clang22-cross, requires: $(tr '\n' ' ' < "$t/rx")"
grep -qx 'longboat>=20261019.1' "$t/rx" || fail "cross pkg must require longboat>=20261019.1, requires: $(tr '\n' ' ' < "$t/rx")"
grep -qx 'sdk109' "$t/rx" || fail "cross pkg must require sdk109, requires: $(tr '\n' ' ' < "$t/rx")"
grep -q 'clang22-cross' "$t/rn" && fail "native pkg must not require clang22-cross"
echo "ok: requires"
for p in xn xx; do
  for comp in "$t/$p"/*.pkg; do
    case "$comp" in *base*) continue ;; esac
    [ -f "$comp/Scripts/preinstall" ] || continue
    grep -q 'needs' "$comp/Scripts/preinstall" || fail "$p: the preinstall refuses a missing requirement"
  done
done

# spec: build/package.sh -- floors: 10.9.5 for native, CROSS_MIN_OS for cross; host-arch x86_64 and arm64
grep -q 'os-version min="10.9.5"' "$t/xn/Distribution" || fail "native floor is 10.9.5"
grep -q "os-version min=\"$CROSS_MIN_OS\"" "$t/xx/Distribution" || fail "cross floor is $CROSS_MIN_OS"
grep -q 'hostArchitectures="x86_64"' "$t/xn/Distribution" || fail "native host arch is x86_64"
grep -q 'hostArchitectures="arm64"' "$t/xx/Distribution" || fail "cross host arch is arm64"
echo "ok: floors"

# spec: build/package.sh -- the cross tree's SDKs is a link into Longboat's sdk109
[ "$(readlink "$t/vx/usr/local/mavergreen/go$GO_LINE-cross/SDKs")" = ../sdk109/SDKs ] || fail "cross SDKs link"

# spec: build/package.sh -- no AppleDouble entries in either payload
for p in xn xx; do
  for comp in "$t/$p"/*.pkg; do
    gzip -dc "$comp/Payload" | cpio -it 2>/dev/null | grep -q '/\._\|^\._' && fail "$p: ._ entries in the payload"
  done
done
echo "ok: no ._ entries"

# spec: build/package.sh -- the welcome text says what the toolchain needs: clang22, no Command Line Tools; no placeholder left
w=$(find "$t/xn" -name 'Welcome.html' | sed -n 1p)
[ -n "$w" ] || fail "no Welcome.html in the native pkg"
grep -q "Go 1\.27" "$w" || fail "Welcome.html names the Go line"
grep -q 'clang22' "$w" || fail "Welcome.html says clang22 is needed"
grep -q 'Command Line Tools' "$w" || fail "Welcome.html says no Command Line Tools are needed"
grep -q '@' "$w" && fail "Welcome.html has an unsubstituted @...@ placeholder"
[ -n "$(find "$t/xn" -name 'LICENSE.txt')" ] || fail "no LICENSE.txt in the native pkg"
echo "ok: welcome"

# spec: build/package.sh -- the build record carries the inputs, and the versions c-toolchain.sh actually used (a dev build can drift)
for v in native cross; do
  f="$WORK/out/build-info-$v.txt"
  [ -f "$f" ] || fail "no $f"
  grep -qx "variant=$v" "$f" || fail "$f: variant"
  grep -qx 'built_clang22=22.1.8-mavericks.99' "$f" || fail "$f: built_clang22 from cc/versions: $(cat "$f")"
  grep -qx "go_version=$GO_VERSION" "$f" || fail "$f: go_version"
  grep -qx "port_version=$(tr -d "[:space:]" < "$here/UPSTREAM_VERSION")" "$f" || fail "$f: port_version (the port's UPSTREAM_VERSION)"
done
echo "PASS: package"
