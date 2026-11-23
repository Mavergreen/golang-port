#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/c-toolchain.sh: checks the installed products against the line's pins and prints the path of the
#       build-time CC wrapper (<WORK>/cc/bin/clang). usage: LINE_ROOT=<line checkout> sh build/c-toolchain.sh
#       Go hashes the C compiler's absolute paths into build IDs, so the products are at the family's installed prefixes
#       on every host (on Linux too, where install@v1 `products:` puts each at its macOS pkg's prefix) and the script
#       never falls back to a cache path. MAVERGREEN_PREFIX relocates them for tests only.
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
[ $# -eq 0 ] || { echo "c-toolchain.sh: unknown argument $1 (usage: c-toolchain.sh)" >&2; exit 2; }
. "$PORT_DIR/build/env.sh" || exit $?

MG="${MAVERGREEN_PREFIX:-/usr/local/mavergreen}"

# spec: PORT.md, the build chain -- the version a product reports is its mavergreen.plist's <key>version</key> string, never `clang --version`.
plist_version() {
  sed -n '/<key>version<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$1/mavergreen.plist" 2>/dev/null | sed -n 1p
}

# spec: PORT.md, the build chain -- a product that is missing or at another version exits 1, naming both versions and the install command.
refuse() { echo "c-toolchain.sh: $*" >&2; exit 1; }

# spec: PORT.md, the build chain -- pins are strict (version drift refuses) when CI=true or MAVERGREEN_STRICT_PINS=1, lenient on a dev box
#       (drift warns once per product and the build goes on); MAVERGREEN_STRICT_PINS=0 forces lenient even in CI. Missing products,
#       a missing SDK and a missing x86_64 slice refuse in every mode.
PINS=lenient
if [ "${MAVERGREEN_STRICT_PINS:-}" = 1 ] || { [ "${CI:-}" = true ] && [ "${MAVERGREEN_STRICT_PINS:-}" != 0 ]; }; then PINS=strict; fi

# spec: build/c-toolchain.sh -- check_product <short> <prefix> <want-version> <install-hint>; sets CP_HAVE
check_product() {
  CP_HAVE="$(plist_version "$2")"
  [ -n "$CP_HAVE" ] || refuse "$1 is not installed at $2 (no mavergreen.plist); want $3. Install it: $4"
  [ "$CP_HAVE" = "$3" ] && return 0
  [ "$PINS" = strict ] && refuse "$1 at $2 is $CP_HAVE, but the line pins $3. Install it: $4"
  echo "c-toolchain.sh: warning: $1 at $2 is $CP_HAVE, but the line pins $3; this build comes from other bytes than a release does and will not match one" >&2
}

# spec: PORT.md, the build chain -- on an Apple Silicon Mac the family compiler is clang22-cross, because clang22's pkg is x86_64-only. A
#       build there is interface-equal to Linux/10.9, not byte-equal: its build IDs hash another compiler path.
CLANG_DIR=clang22
if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] && [ -f "$MG/clang22-cross/mavergreen.plist" ]; then
  CLANG_DIR=clang22-cross
  echo "c-toolchain.sh: Apple Silicon: using $MG/clang22-cross in place of clang22; this build will be interface-equal, not byte-equal, to Linux/10.9" >&2
fi
CLANG_PREFIX="$MG/$CLANG_DIR"
check_product "$CLANG_DIR" "$CLANG_PREFIX" "$CLANG22_VERSION" \
  "macOS: sudo installer -pkg $CLANG_DIR-$CLANG22_VERSION.pkg -target /; Linux: list $CLANG_DIR@$CLANG22_VERSION under install@v1 products:"
CLANG_HAVE="$CP_HAVE"

# spec: PORT.md, the build chain -- the installed SDK's version is not pinned by the line, only its presence.
SDK109="$MG/sdk109/SDKs/MacOSX10.9.sdk"
[ -d "$SDK109" ] || refuse "sdk109 is not installed: no $SDK109. Install it: macOS: sudo longboat sdk install 10.9; Linux: list sdk109@<any release> under install@v1 products:"
# spec: PORT.md, the build chain -- an SDK without SDKSettings.json (sdk109 from Longboat before 20261027) makes clang22 write "sdk n/a" into
#       every C object's build-version command, so cgo's bytes and every downstream Go build ID differ from CI's: refuse it, naming the fix.
[ -f "$SDK109/SDKSettings.json" ] || refuse "sdk109 at $SDK109 has no SDKSettings.json, so its C objects would differ from CI's. Reinstall it: macOS: sudo longboat sdk install 10.9 with a current Longboat; Linux: list sdk109@<latest release> under install@v1 products:"

RECAULK_LIB="$MG/recaulk/lib/librecaulk.a"
check_product recaulk "$MG/recaulk" "$RECAULK_VERSION" \
  "macOS: sudo installer -pkg recaulk-$RECAULK_VERSION.pkg -target /; Linux: list recaulk@$RECAULK_VERSION under install@v1 products:"
RECAULK_HAVE="$CP_HAVE"
[ -f "$RECAULK_LIB" ] || refuse "recaulk $RECAULK_VERSION has no $RECAULK_LIB; reinstall it (Linux: list recaulk@$RECAULK_VERSION under install@v1 products:)"
# spec: PORT.md, the build chain -- Mach-O reads go through the clang22 prefix's llvm-lipo (no lipo on Linux).
_archs="$("$CLANG_PREFIX/bin/llvm-lipo" -info "$RECAULK_LIB" 2>/dev/null | sed -n 's/.*: //p')" || refuse "$CLANG_PREFIX/bin/llvm-lipo could not read $RECAULK_LIB"
case " $_archs " in
  *" x86_64 "*) ;;
  *) refuse "$RECAULK_LIB has no x86_64 slice (has: $_archs); reinstall recaulk $RECAULK_VERSION" ;;
esac

# spec: PORT.md, the build chain -- the build wrapper adds the same flags as the shipped ones (build/cc-wrapper.sh), at the paths checked above.
# spec: PORT.md, the build chain -- the wrapper answers Go's --print-prog-name for strip, dsymutil and ar from the clang22 prefix
#       (build/cc-wrapper.sh), so those tools must be there: a prefix without one refuses rather than build with other bytes.
for _tool in dsymutil llvm-strip llvm-ar; do
  [ -x "$CLANG_PREFIX/bin/$_tool" ] || refuse "$CLANG_DIR at $CLANG_PREFIX has no bin/$_tool, which Go's darwin link needs (a host's own would change the bytes). Install a $CLANG_DIR that ships it"
done
CC_DIR="$WORK/cc/bin"
mkdir -p "$CC_DIR" || exit 1
# spec: PORT.md, the build chain -- an earlier version left a strip link here; the wrapper's answer is now the only mechanism.
rm -f "$CC_DIR/strip"
. "$PORT_DIR/build/cc-wrapper.sh"
cc_wrapper "$CC_DIR/clang" "cc_prefix='$CLANG_PREFIX'
sdk='$SDK109'
recaulk='$RECAULK_LIB'
no_clang='$CLANG_DIR is gone from $CLANG_PREFIX; run build/c-toolchain.sh again'
no_sdk='sdk109 is gone from $SDK109; run build/c-toolchain.sh again'" || exit 1
# spec: PORT.md, the build chain -- the paths the wrapper was written with, for the build scripts to source (build/toolchain-lib.sh)
printf "cc_prefix='%s'\nsdk='%s'\nrecaulk='%s'\n" "$CLANG_PREFIX" "$SDK109" "$RECAULK_LIB" > "$WORK/cc/vars"
# spec: PORT.md, the build chain -- the versions actually used, for build-info (Task 7 copies this file)
sdkv() { _v="$(plist_version "$1")"; printf %s "${_v:-unknown}"; }
{
  echo "clang22=$CLANG_HAVE"
  echo "recaulk=$RECAULK_HAVE"
  echo "sdk109=$(sdkv "$MG/sdk109")"
  echo "pins=$PINS"
} > "$WORK/cc/versions"
echo "$CC_DIR/clang"
