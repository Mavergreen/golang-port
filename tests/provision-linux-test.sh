#!/bin/sh
# platform: host-agnostic
# spec: build/provision-linux.sh -- the layout and plists a pkg install leaves, idempotence and the Darwin refusal, against a
#       file:// release tree (MAVERGREEN_RELEASES), a file:// SDK pin (MAVERICKS_SDK_URL) and private caches
here=$(cd "$(dirname "$0")/.." && pwd)
SY="${SHIPYARD_SCRIPTS:-/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/scripts}"
[ -f "$SY/fetch_product_tar.sh" ] || { echo "skip: no shipyard scripts at $SY (install shipyard or set SHIPYARD_SCRIPTS)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "skip: no python3, which shipyard's fetch_product_tar.sh needs"; exit 77; }
ST=$(sh "$SY/fetch_stevedore.sh" 2>/dev/null) || { echo "skip: no stevedore (offline, and none cached) to build the fixture pkgs with"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/provision-linux-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
if command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$@"; }; else sha() { sha256sum "$@"; }; fi

CV=22.1.8-mavericks.25; RV=20261122.4; RV2=20261122.5; LB=20261027.13; LB2=20261027.12
rel="$t/rel/Mavergreen"

# spec: build/provision-linux.sh -- mkplist <file> <identifier> <product> <version> [require]: a fixture product manifest
mkplist() {
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
    printf '  <key>identifier</key>\n  <string>%s</string>\n  <key>product</key>\n  <string>%s</string>\n' "$2" "$3"
    printf '  <key>version</key>\n  <string>%s</string>\n  <key>requires</key>\n  <array>\n' "$4"
    [ -z "${5:-}" ] || printf '    <string>%s</string>\n' "$5"
    printf '  </array>\n</dict>\n</plist>\n'
  } > "$1"
}

# spec: build/provision-linux.sh -- mkpkg <stage root> <identifier> <version> <out>: a product archive of one component, as a release ships
mkpkg() {
  w="$t/pkgwork"; rm -rf "$w"; mkdir -p "$w"
  "$ST" component --root "$1" --identifier "$2" --version "$3" --install-location / --mtime 0 --out "$w/c.pkg" >/dev/null || fail "stevedore component"
  cat > "$w/d.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <pkg-ref id="$2"/>
  <choices-outline><line choice="default"><line choice="$2"/></line></choices-outline>
  <choice id="default"/>
  <choice id="$2" visible="false"><pkg-ref id="$2"/></choice>
  <pkg-ref id="$2" version="$3" onConclusion="none">c.pkg</pkg-ref>
</installer-gui-script>
XML
  "$ST" product --distribution "$w/d.xml" --package "$w/c.pkg" --mtime 0 --out "$4" >/dev/null || fail "stevedore product"
}

sums() { ( cd "$1" && sha * > SHA256SUMS ); }

# spec: build/provision-linux.sh -- the clang22 fixture: the linux archive, the native pkg (which carries the plist) and the appcast naming it
d="$rel/clang-22/releases/download/$CV"; mkdir -p "$d" "$t/ct/opt/mavergreen/clang22/bin"
printf '#!/bin/sh\necho fixture clang\n' > "$t/ct/opt/mavergreen/clang22/bin/clang-22"; chmod 755 "$t/ct/opt/mavergreen/clang22/bin/clang-22"
ln -s clang-22 "$t/ct/opt/mavergreen/clang22/bin/clang"
( cd "$t/ct" && tar -cf - opt ) | gzip -n > "$d/clang22-$CV-linux-x86_64.tar.gz"
mkdir -p "$t/cp/usr/local/mavergreen/clang22/bin"
mkplist "$t/cp/usr/local/mavergreen/clang22/mavergreen.plist" dev.mavergreen.clang.clang22 clang22 "$CV" sdk109
cp "$t/cp/usr/local/mavergreen/clang22/mavergreen.plist" "$t/clang22.plist"
echo darwin-clang > "$t/cp/usr/local/mavergreen/clang22/bin/clang-22"
mkpkg "$t/cp" dev.mavergreen.clang.clang22 "$CV" "$d/mavericks-clang-22-native-$CV.pkg"
mkpkg "$t/cp" dev.mavergreen.clang.clang22-cross "$CV" "$d/mavericks-clang-22-cross-$CV.pkg"
printf '<rss><channel><item>\n<enclosure url="https://github.com/Mavergreen/clang-22/releases/download/%s/mavericks-clang-22-native-%s.pkg" length="1"\n type="application/octet-stream"/></item></channel></rss>\n' "$CV" "$CV" > "$d/clang22.xml"
sums "$d"

# spec: build/provision-linux.sh -- the recaulk fixture: two releases, each pkg's component tree carrying lib/librecaulk.a and its plist
for v in "$RV" "$RV2"; do
  d="$rel/recaulk/releases/download/$v"; r="$t/rp-$v/usr/local/mavergreen/recaulk"; mkdir -p "$d" "$r/lib" "$r/include/recaulk"
  echo "$v" > "$r/lib/librecaulk.a"
  mkplist "$r/mavergreen.plist" dev.mavergreen.recaulk recaulk "$v"
  cp "$r/mavergreen.plist" "$t/recaulk-$v.plist"
  mkpkg "$t/rp-$v" dev.mavergreen.recaulk "$v" "$d/recaulk-$v.pkg"
  sums "$d"
done

# spec: build/provision-linux.sh -- the sdk109 fixture: longboat's latest release, and the SDK pin served from a file
mkdir -p "$rel/longboat/releases" "$t/sdk/MacOSX10.9.sdk/usr/lib"
echo "$LB" > "$rel/longboat/releases/latest"
echo stub > "$t/sdk/MacOSX10.9.sdk/usr/lib/libSystem.B.dylib"
ln -s libSystem.B.dylib "$t/sdk/MacOSX10.9.sdk/usr/lib/libSystem.dylib"
( cd "$t/sdk" && tar -cf MacOSX10.9.sdk.tar.xz MacOSX10.9.sdk )
sdksha=$(sha "$t/sdk/MacOSX10.9.sdk.tar.xz" | cut -c1-64)

# spec: build/provision-linux.sh -- prov <uname> <root> args...: stdout+stderr in $t/log, status in $rc
prov() {
  u=$1; shift
  rc=0
  MAVERGREEN_UNAME_S=$u SHIPYARD_SCRIPTS="$SY" STEVEDORE="$ST" MAVERGREEN_RELEASES="file://$t/rel" \
    MAVERGREEN_PKG_CACHE="$t/pc" MAVERGREEN_TAR_CACHE="$t/tc" MAVERICKS_SDK_CACHE="$t/sc" \
    MAVERICKS_SDK_URL="file://$t/sdk/MacOSX10.9.sdk.tar.xz" MAVERICKS_SDK_SHA256="$sdksha" \
    sh "$here/build/provision-linux.sh" "$@" > "$t/log" 2>&1 || rc=$?
}
has() { grep -qF -- "$1" "$t/log" || fail "$2: want '$1' in: $(cat "$t/log")"; }
key() { sed -n "/<key>$2<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}" "$1" | sed -n 1p; }

R="$t/root"; MG="$R/usr/local/mavergreen"
prov Linux --root "$R" "clang22@$CV" sdk109 "recaulk@$RV"
[ "$rc" = 0 ] || fail "first run: exit $rc: $(cat "$t/log")"

# spec: build/provision-linux.sh -- the layout: each product's tree at its pkg's prefix, and nothing else beside them
[ "$(ls -A "$MG" | tr '\n' ' ')" = "clang22 recaulk sdk109 " ] || fail "want exactly clang22 recaulk sdk109 in $MG, have: $(ls -A "$MG" | tr '\n' ' ')"
[ -x "$MG/clang22/bin/clang" ] || fail "no executable $MG/clang22/bin/clang"
[ "$("$MG/clang22/bin/clang")" = "fixture clang" ] || fail "clang22/bin/clang is not the linux archive's"
[ ! -e "$MG/clang22/.mavergreen-archive-sha256" ] || fail "clang22 keeps fetch_product_tar.sh's cache stamp, which no pkg installs"
[ -f "$MG/sdk109/SDKs/MacOSX10.9.sdk/usr/lib/libSystem.B.dylib" ] || fail "no SDK at $MG/sdk109/SDKs/MacOSX10.9.sdk"
[ -L "$MG/sdk109/SDKs/MacOSX10.9.sdk/usr/lib/libSystem.dylib" ] || fail "the SDK's symlinks were not kept as links"
[ -f "$MG/recaulk/lib/librecaulk.a" ] && [ -d "$MG/recaulk/include/recaulk" ] || fail "recaulk's lib/ and include/ are not at $MG/recaulk"

# spec: build/provision-linux.sh -- each plist is the pkg's own (clang22, recaulk), or rendered as longboat renders sdk109's
cmp -s "$t/clang22.plist" "$MG/clang22/mavergreen.plist" || fail "clang22's mavergreen.plist is not the release pkg's: $(cat "$MG/clang22/mavergreen.plist")"
cmp -s "$t/recaulk-$RV.plist" "$MG/recaulk/mavergreen.plist" || fail "recaulk's mavergreen.plist is not the release pkg's"
p="$MG/sdk109/mavergreen.plist"
[ "$(key "$p" identifier)" = dev.mavergreen.longboat.sdk109 ] && [ "$(key "$p" product)" = sdk109 ] \
  && [ "$(key "$p" version)" = "$LB" ] && [ "$(key "$p" name)" = "Mac OS X 10.9 SDK" ] \
  || fail "sdk109's plist is not longboat's for $LB: $(cat "$p")"
has "installed clang22 $CV" "first run"

# spec: build/provision-linux.sh -- idempotent: the same versions again are kept, trees untouched
for s in clang22 sdk109 recaulk; do echo mark > "$MG/$s/.mark"; done
prov Linux --root "$R" "clang22@$CV" sdk109 "recaulk@$RV"
[ "$rc" = 0 ] || fail "second run: exit $rc: $(cat "$t/log")"
has "kept clang22 $CV" "second run"; has "kept sdk109 $LB" "second run"; has "kept recaulk $RV" "second run"
for s in clang22 sdk109 recaulk; do [ -f "$MG/$s/.mark" ] || fail "second run replaced $s, which was already at its version"; done
[ "$(ls -A "$MG" | tr '\n' ' ')" = "clang22 recaulk sdk109 " ] || fail "second run left: $(ls -A "$MG" | tr '\n' ' ')"

# spec: build/provision-linux.sh -- another pinned version replaces the whole tree; a named longboat tag re-versions sdk109
prov Linux --root "$R" "recaulk@$RV2" "sdk109@$LB2"
[ "$rc" = 0 ] || fail "upgrade: exit $rc: $(cat "$t/log")"
has "replacing recaulk $RV at $MG/recaulk with $RV2" "upgrade"
[ ! -e "$MG/recaulk/.mark" ] || fail "the recaulk upgrade kept a file of the old tree"
cmp -s "$t/recaulk-$RV2.plist" "$MG/recaulk/mavergreen.plist" || fail "recaulk's plist is not $RV2's"
[ "$(key "$MG/sdk109/mavergreen.plist" version)" = "$LB2" ] || fail "sdk109@$LB2 did not re-version sdk109"
[ -f "$MG/clang22/.mark" ] || fail "a run that did not name clang22 touched it"

# spec: build/provision-linux.sh -- Darwin refuses before touching anything (macOS installs through install@v1 or Longboat)
prov Darwin --root "$t/darwin" "clang22@$CV"
[ "$rc" = 1 ] || fail "Darwin: want exit 1, got $rc: $(cat "$t/log")"
has 'install@v1 `products:` or Longboat' "Darwin"
[ ! -e "$t/darwin" ] || fail "Darwin: the refusal created $t/darwin"
if [ "$(uname -s)" = Darwin ]; then
  rc=0; SHIPYARD_SCRIPTS="$SY" sh "$here/build/provision-linux.sh" --root "$t/darwin" sdk109 > "$t/log" 2>&1 || rc=$?
  [ "$rc" = 1 ] || fail "on this Darwin host: want exit 1, got $rc: $(cat "$t/log")"
fi

# spec: build/provision-linux.sh -- a product it does not provision, or one with no version, is a usage error
prov Linux --root "$R" sdk113
[ "$rc" = 2 ] || fail "sdk113: want exit 2, got $rc"
prov Linux --root "$R" clang22
[ "$rc" = 2 ] || fail "clang22 with no version: want exit 2, got $rc"

echo "PASS: provision-linux"
