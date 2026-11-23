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
# spec: tests/package-test.sh -- an older shipyard may lack the standalone seams and skips; one that says it is 1.0.845 or later
#       (its installed MavericksShipyardConfigVersion.cmake, else SHIPYARD_VERSION, as build-base-component.sh reads it) must have them
sv=""
if [ -f "$SHIPYARD_SCRIPTS/../MavericksShipyardConfigVersion.cmake" ]; then
  sv="$(sed -n 's/.*set(PACKAGE_VERSION "\([^"]*\)").*/\1/p' "$SHIPYARD_SCRIPTS/../MavericksShipyardConfigVersion.cmake" | head -1)"
fi
[ -n "$sv" ] || sv="${SHIPYARD_VERSION:-}"
new_enough=no
case "$sv" in
  ''|.*|*.|*..*|*[!0-9.]*) ;;
  *) [ "$(awk -v a="$sv" 'BEGIN { split(a, v, "."); print (v[1] * 1000000 + v[2] * 1000 + v[3] >= 1000845) ? "yes" : "no" }')" = yes ] && new_enough=yes ;;
esac
for s in stage_standalone.sh check-standalone-archive.sh; do
  [ -f "$SHIPYARD_SCRIPTS/$s" ] && continue
  [ "$new_enough" = no ] || { echo "FAIL: shipyard $sv at $SHIPYARD_SCRIPTS has no $s, which 1.0.845 and later ship"; exit 1; }
  echo "no shipyard with $s (shipyard ${sv:-of unknown version}, older than 1.0.845) -- skipping"; exit 77
done
export SHIPYARD_SCRIPTS
sd=$(sh "$SHIPYARD_SCRIPTS/fetch_stevedore.sh" 2>"$t/sd.err") || { cat "$t/sd.err"; echo "no stevedore -- skipping"; exit 77; }

fx="$here/tests/fixtures/line-127"
LINE_ROOT="$fx"; MAVERICKS_WORK="$t/work"; SOURCE_DATE_EPOCH=1700000000; UPD_APP="$t/no-updater.app"
export LINE_ROOT MAVERICKS_WORK SOURCE_DATE_EPOCH UPD_APP
unset MAVERICKS_ROOT
PORT_DIR="$here"; export PORT_DIR
. "$here/build/env.sh" || exit $?

mk() { mkdir -p "${1%/*}"; printf '#!/bin/sh\n' > "$1"; chmod 755 "$1"; }
# spec: build/package.sh -- the archive's arch is read from the executables' Mach-O headers: a thin 64-bit header, cputype x86_64 or arm64
macho() {
  mkdir -p "${1%/*}"
  case "$2" in
    x86_64) printf '\317\372\355\376\007\000\000\001\003\000\000\000\002\000\000\000' > "$1" ;;
    arm64) printf '\317\372\355\376\014\000\000\001\000\000\000\000\002\000\000\000' > "$1" ;;
  esac
  chmod 755 "$1"
}
n="$WORK/staging$PREFIX"; c="$WORK/staging-cross$CROSS_PREFIX"
for f in bin/go bin/gofmt pkg/tool/darwin_amd64/compile; do macho "$n/$f" x86_64; done
mk "$n/bin/mavericks-clang"
mkdir -p "$n/etc/openssl/certs"; : > "$n/etc/openssl/certs/ca-certificates.crt"; echo license > "$n/LICENSE"
for f in bin/go bin/gofmt pkg/tool/darwin_arm64/compile; do macho "$c/$f" arm64; done
mk "$c/bin/mavericks-cross-clang"
# spec: build/package.sh -- crypto/x509's CA-bundle defaults (PORT.md invariant 7) name family paths, as the real overlay does; the line's
#       standalone-text deviation excuses them, so the checker must be handed the line's INGREDIENTS.md
for r in "$n" "$c"; do
  mkdir -p "$r/src/crypto/x509"
  printf 'package x509\n\nvar p = []string{"/usr/local/mavergreen/ca-certs/etc/openssl/certs/ca-certificates.crt", "%s/etc/openssl/certs/ca-certificates.crt"}\n' \
    "$PREFIX" > "$r/src/crypto/x509/root_keychainunion_darwin.go"
done
# spec: build/package.sh -- a group-writable staged file: the payload and the archive both drop the bit, and the staging keeps it
chmod 775 "$n/bin/gofmt"
ln -s ../sdk109/SDKs "$c/SDKs"
: > "$n/._AppleDouble"
mkdir -p "$WORK/cc"
printf 'clang22=22.1.8-mavericks.99\nrecaulk=20261122.3\nsdk109=20261012.2\npins=lenient\n' > "$WORK/cc/versions"

# spec: tests/package-test.sh -- check-standalone-archive.sh reads every Mach-O with llvm tools: stubs that read the stub headers above, so
#       this test needs no clang22. Each prints what llvm-otool would for a thin executable that loads only libSystem.
L="$t/llvm"; mkdir -p "$L"
cat > "$L/llvm-otool" <<'STUB'
#!/bin/sh
f=""; for a in "$@"; do f="$a"; done
case "$(od -An -tx1 -j4 -N1 "$f" | tr -d ' ')" in 07) a=X86_64 ;; 0c) a=ARM64 ;; *) echo "not Mach-O: $f" >&2; exit 1 ;; esac
case "$1" in
  -hv) printf 'Mach header\n      magic  cputype cpusubtype  caps    filetype ncmds sizeofcmds      flags\nMH_MAGIC_64 %s ALL 0x00 EXECUTE 1 56 NOUNDEFS\n' "$a" ;;
  -l) printf 'Load command 0\n          cmd LC_LOAD_DYLIB\n      cmdsize 56\n         name /usr/lib/libSystem.B.dylib (offset 24)\n' ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$L/llvm-nm"
printf '#!/bin/sh\necho "stub $0: not used for thin files" >&2; exit 1\n' > "$L/llvm-lipo"
cp "$L/llvm-lipo" "$L/llvm-ar"
chmod 755 "$L"/llvm-*
OTOOL="$L/llvm-otool"; LIPO="$L/llvm-lipo"; NM="$L/llvm-nm"; export OTOOL LIPO NM

# spec: build/package.sh -- both pkgs build from a staged tree and print their paths: the standalone archive's, then the pkg's last
sh "$here/build/package.sh" native > "$t/native.out" 2> "$t/native.err" || { cat "$t/native.err"; fail "native must package from a staged tree"; }
sh "$here/build/package.sh" cross > "$t/cross.out" 2> "$t/cross.err" || { cat "$t/cross.err"; fail "cross must package from a staged tree"; }
base="${PKG_VERSION#*-}"
np="$WORK/out/golang-$GO_VERSION-native-$base.pkg"; xp="$WORK/out/golang-$GO_VERSION-cross-$base.pkg"
[ -f "$np" ] && [ -f "$xp" ] || fail "want $np and $xp"
[ "$(tail -1 "$t/native.out")" = "$np" ] || fail "native prints its pkg path last, got: $(tail -1 "$t/native.out")"
[ "$(tail -1 "$t/cross.out")" = "$xp" ] || fail "cross prints its pkg path last"
echo "ok: both packages built"

# spec: build/package.sh -- the standalone archives, named for the arch read from the executables: x86_64 native, arm64 cross
na="$WORK/out/go$GO_LINE-$PKG_VERSION-macos-x86_64.tar.gz"; xa="$WORK/out/go$GO_LINE-cross-$PKG_VERSION-macos-arm64.tar.gz"
[ -f "$na" ] && [ -f "$xa" ] || fail "want $na and $xa; out has: $(ls "$WORK/out" | tr '\n' ' ')"
[ "$(sed -n 1p "$t/native.out")" = "$na" ] || fail "native prints the archive's path before the pkg's, got: $(cat "$t/native.out")"
[ "$(sed -n 1p "$t/cross.out")" = "$xa" ] || fail "cross prints the archive's path before the pkg's, got: $(cat "$t/cross.out")"
grep -q 'check-standalone-archive: ok' "$t/native.err" || fail "native: the checker did not pass the archive: $(cat "$t/native.err")"
grep -q 'check-standalone-archive: ok' "$t/cross.err" || fail "cross: the checker did not pass the archive"
tar -tzf "$na" | sed 's#/$##' | LC_ALL=C sort > "$t/na.list"; tar -tzf "$xa" | sed 's#/$##' | LC_ALL=C sort > "$t/xa.list"
top="go$GO_LINE-$PKG_VERSION"; xtop="go$GO_LINE-cross-$PKG_VERSION"
grep -qx "$top/bin/go" "$t/na.list" || fail "native archive has no $top/bin/go: $(tr '\n' ' ' < "$t/na.list")"
grep -qx "$top/etc/openssl/certs/ca-certificates.crt" "$t/na.list" || fail "native archive has no CA bundle"
grep -qx "$xtop/bin/go" "$t/xa.list" || fail "cross archive has no $xtop/bin/go"
grep -q 'mavergreen\.plist$' "$t/na.list" "$t/xa.list" && fail "an archive holds the pkg manifest"
grep -qx "$xtop/SDKs" "$t/xa.list" && fail "the cross archive holds the SDKs link: sdk109 is a require, the wrapper finds the SDK"
grep -q 'excused by standalone-text:src/crypto/x509/root_keychainunion_darwin\*\.go' "$t/native.err" "$t/cross.err" \
  || fail "the line's standalone-text deviation did not excuse crypto/x509's defaults: $(cat "$t/native.err")"
# spec: build/package.sh -- the archive is staged after build_component_pkg.sh normalises modes, so it agrees with the pkg
m="$(tar -tvzf "$na" | awk -v p="$top/bin/gofmt" '$NF == p { print $1 }')"
[ "$m" = -rwxr-xr-x ] || fail "the archive's bin/gofmt is '$m', want -rwxr-xr-x (group write dropped, as in the pkg)"
[ -n "$(find "$n/bin/gofmt" -perm -020)" ] || fail "package.sh changed the staging's modes"
echo "ok: standalone archives"
# spec: build/package.sh -- the pkg root keeps its SDKs link (the archive is staged from a filtered copy), and the copy is gone
[ "$(readlink "$WORK/pkgroot-cross$CROSS_PREFIX/SDKs")" = ../sdk109/SDKs ] || fail "package.sh dropped SDKs from the cross pkg root"
[ ! -e "$WORK/standalone-cross" ] || fail "package.sh left its filtered copy at $WORK/standalone-cross"
for v in native cross; do
  case "$v" in native) w=x86_64 ;; *) w=arm64 ;; esac
  grep -qx "arch=$w" "$WORK/out/build-info-$v.txt" || fail "build-info-$v.txt: arch=$w, read from the executables"
done
echo "ok: pkg root unchanged"

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
#       clang22-cross; both require sdk109, and neither requires Longboat (maintainer ruling 2026-11-20, check at use)
reqs() { sed -n '/<key>requires<\/key>/,/<\/array>/p' "$(mf "$1" "$2")" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | sed 's/&gt;/>/g'; }
reqs vn go$GO_LINE > "$t/rn"; reqs vx go$GO_LINE-cross > "$t/rx"
grep -qx 'clang22' "$t/rn" || fail "native pkg must require clang22, requires: $(tr '\n' ' ' < "$t/rn")"
grep -qx 'clang22-cross' "$t/rx" || fail "cross pkg must require clang22-cross, requires: $(tr '\n' ' ' < "$t/rx")"
grep -q 'longboat' "$t/rx" && fail "cross pkg must not require Longboat (check at use), requires: $(tr '\n' ' ' < "$t/rx")"
grep -qx 'sdk109' "$t/rx" || fail "cross pkg must require sdk109, requires: $(tr '\n' ' ' < "$t/rx")"
grep -qx 'sdk109' "$t/rn" || fail "native pkg must require sdk109 (its wrapper names it), requires: $(tr '\n' ' ' < "$t/rn")"
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

# spec: build/package.sh -- the pkg root and the cross archive's filtered copy keep the staging's modes under any umask (an unpacking tar
#       would have made them 0700 here), and the filtered copy is gone
(umask 077 && sh "$here/build/package.sh" cross) > "$t/u77.out" 2> "$t/u77.err" || { cat "$t/u77.err"; fail "cross must package under umask 077"; }
m="$(tar -tvzf "$xa" | awk -v p="$xtop/bin/go" '$NF == p { print $1 }')"
[ "$m" = -rwxr-xr-x ] || fail "under umask 077 the cross archive's bin/go is '$m', want -rwxr-xr-x"
[ ! -e "$WORK/standalone-cross" ] || fail "package.sh left its filtered copy at $WORK/standalone-cross"
echo "ok: modes kept under umask 077"
# spec: build/package.sh -- a failed stage_standalone.sh leaves no filtered copy behind
mkdir "$t/ship"; cp -R "$SHIPYARD_SCRIPTS"/. "$t/ship/"
printf '#!/bin/sh\necho "stage_standalone: stub failure" >&2\nexit 1\n' > "$t/ship/stage_standalone.sh"
SHIPYARD_SCRIPTS="$t/ship" sh "$here/build/package.sh" cross > "$t/sf.out" 2> "$t/sf.err" && fail "cross packaged although stage_standalone.sh failed"
grep -q 'stub failure' "$t/sf.err" || fail "the stub stage_standalone.sh did not run: $(tail -5 "$t/sf.err")"
[ ! -e "$WORK/standalone-cross" ] || fail "a failed stage_standalone.sh left the filtered copy at $WORK/standalone-cross"
echo "ok: a failed stage_standalone leaves no copy"

# spec: build/package.sh -- refusals: a toolchain of two arches, and an archive the checker refuses, fail the package
macho "$n/pkg/tool/darwin_amd64/link" arm64
sh "$here/build/package.sh" native > "$t/mixed.out" 2> "$t/mixed.err" && fail "native packaged a toolchain whose executables are two arches"
grep -q 'both x86_64 and arm64' "$t/mixed.err" || fail "the two-arch refusal names both: $(cat "$t/mixed.err")"
rm -f "$n/pkg/tool/darwin_amd64/link"
printf '#!/bin/sh\nexec /usr/local/mavergreen/go%s/bin/go "$@"\n' "$GO_LINE" > "$n/bin/self"; chmod 755 "$n/bin/self"
sh "$here/build/package.sh" native > "$t/self.out" 2> "$t/self.err" && fail "native packaged an archive whose script names its own prefix"
grep -q 'self-reference' "$t/self.err" || fail "the checker's finding is shown: $(cat "$t/self.err")"
grep -q 'check-standalone-archive.sh refused' "$t/self.err" || fail "package.sh says the checker refused: $(cat "$t/self.err")"
rm -f "$n/bin/self"
# spec: build/package.sh -- without the line's deviation, the CA-bundle defaults are findings (the self-reference and ca-certs)
cp -R "$fx" "$t/line-nodev"; rm -f "$t/line-nodev/INGREDIENTS.md"
LINE_ROOT="$t/line-nodev" sh "$here/build/package.sh" native > "$t/nodev.out" 2> "$t/nodev.err" && fail "native packaged with no standalone-text deviation in the line"
grep -q 'root_keychainunion_darwin.go names /usr/local/mavergreen/ca-certs' "$t/nodev.err" || fail "the undeclared ca-certs finding: $(cat "$t/nodev.err")"
echo "ok: refusals"
echo "PASS: package"
