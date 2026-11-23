#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/package.sh: the native or cross toolchain, staged by build-native.sh or build-cross.sh, as a .pkg.
#       usage: LINE_ROOT=<line checkout> [UPD_APP=<updater .app>] [SOURCE_DATE_EPOCH=<n>] sh build/package.sh native|cross
#       Writes $WORK/out/golang-$GO_VERSION-<variant>-mavericks.<N>.pkg, the standalone archive
#       $WORK/out/go1NN[-cross]-$PKG_VERSION-macos-<arch>.tar.gz beside it, and build-info-<variant>.txt; prints the archive's
#       path, then the pkg's path last.
#       Everything goes through shipyard's host-agnostic seams (stage_product.sh, build_component_pkg.sh, set_install_floor.sh,
#       build-info.sh), which build the archive with stevedore, so any host packages -- never pkgbuild, productbuild or pkgutil.
#       The staging is copied first: stage_product.sh writes the manifest into the tree it is given, and the staging stays
#       exactly what the builder made, comparable across hosts.
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
variant="${1:-}"
case "$variant" in native|cross) ;; *) echo "usage: sh build/package.sh native|cross" >&2; exit 2 ;; esac
. "$PORT_DIR/build/env.sh" || exit $?
die() { echo "package.sh: $*" >&2; exit 1; }
# spec: PORT.md, the build chain -- timestamps are the line's commit time, never invented: the seams take $SOURCE_DATE_EPOCH when the caller
#       sets it, else the commit time of $MAVERICKS_ROOT, which is the line checkout being released.
: "${MAVERICKS_ROOT:=$LINE_ROOT}"
export MAVERICKS_ROOT
export COPYFILE_DISABLE=1   # no ._AppleDouble files in copies

out="$WORK/out"
mkdir -p "$out"
gominor="${GO_VERSION%.*}"
rev="${PKG_VERSION#*-}"   # mavericks.<rev>
pkg="$out/golang-$GO_VERSION-$variant-$rev.pkg"
res=""
if [ "$variant" = native ]; then
  src="$WORK/staging"; prefix="$PREFIX"; product="go$GO_LINE"; line="$GO_LINE"
  name="Go $gominor for Mavericks"
  title="go$GO_LINE — modern Go $gominor for OS X 10.9"
  wrapper=mavericks-clang; req=clang22
  upd_default="$MAVERICKS_BUILD_ROOT/golang-updater/go$GO_LINE-updater.app"
else
  src="$WORK/staging-cross"; prefix="$CROSS_PREFIX"; product="go$GO_LINE-cross"; line="$GO_LINE-cross"
  name="Go $gominor cross toolchain for Mavericks"
  title="go$GO_LINE-cross — build 10.9 programs on modern macOS"
  wrapper=mavericks-cross-clang; req=clang22-cross
  upd_default="$MAVERICKS_BUILD_ROOT/golang-updater-cross/go$GO_LINE-cross-updater.app"
fi
[ -x "$src$prefix/bin/go" ] || die "no $src$prefix/bin/go -- run build-$variant.sh first"
[ -x "$src$prefix/bin/$wrapper" ] || die "no $wrapper in $src$prefix/bin -- run build-$variant.sh first"
[ -f "$WORK/cc/versions" ] || die "no $WORK/cc/versions -- c-toolchain.sh (run by build-$variant.sh) writes it"
if [ "$variant" = native ]; then
  [ -f "$src$prefix/etc/openssl/certs/ca-certificates.crt" ] || die "the CA bundle is not staged -- run build-native.sh first"
else
  [ -L "$src$prefix/SDKs" ] || die "no SDKs link in $src$prefix -- run build-cross.sh first"
fi

# spec: PORT.md, the build chain -- the archive's arch is what the toolchain's own executables are, read from their Mach-O headers (bin/ and
#       pkg/tool/), never assumed from the variant: x86_64 or arm64, and exactly one of them. src/ holds other arches' Mach-O testdata.
macho_arch() {
  case "$(od -An -tx1 -N8 "$1" 2>/dev/null | tr -d ' \n')" in
    cffaedfe07000001) echo x86_64 ;;
    cffaedfe0c000001) echo arm64 ;;
    cffaedfe*|cefaedfe*|feedface*|feedfacf*|cafebab*) echo "other($1)" ;;
  esac
}
arch=""
for f in "$src$prefix"/bin/* "$src$prefix"/pkg/tool/*/*; do
  [ -f "$f" ] || continue
  a="$(macho_arch "$f")"
  [ -n "$a" ] || continue
  case "$a" in other*) die "${f#"$src$prefix"/} is a Mach-O that is neither thin x86_64 nor thin arm64" ;; esac
  [ -z "$arch" ] || [ "$arch" = "$a" ] || die "the $variant toolchain's executables are both $arch and $a (${f#"$src$prefix"/})"
  arch="$a"
done
[ -n "$arch" ] || die "no Mach-O executable in $src$prefix/bin or pkg/tool -- run build-$variant.sh first"

# spec: build/package.sh header -- the manifest goes into a copy; ._* entries from any host's tar never ship
root="$WORK/pkgroot-$variant"
rm -rf "$root"
mkdir -p "$root"
# spec: build/package.sh -- cp -p, not an unpacking tar: the pkg's modes are the staging's, whatever this shell's umask
cp -pRP "$src/." "$root/"
find "$root" -name '._*' -exec rm -rf {} + 2>/dev/null || true

# spec: PORT.md, the build chain -- the shipped wrappers call clang22 (clang22-cross for the cross pkg) against sdk109's 10.9 SDK, so the
#       installer requires both. Every darwin/amd64 link is external (GO_EXTLINK_ENABLED), pure-Go programs included, so clang22 and
#       sdk109 are needed by every user. Longboat is not required: sdk109 is what the wrapper uses, however it was installed (maintainer
#       ruling 2026-11-20, check at use; the wrapper's missing-SDK message names 'sudo longboat sdk install 10.9').
scr="$out/pkg-scripts-$variant"
rm -rf "$scr"
set -- --stage "$root" --product "$product" --name "$name" --group go --line "$line" --version "$PKG_VERSION" \
  --exclude "bin/$wrapper" --requires "$req" --scripts-out "$scr"
set -- "$@" --requires sdk109
UPD_APP="${UPD_APP:-$upd_default}"
if [ -d "$UPD_APP" ]; then
  set -- "$@" --updater-app "$UPD_APP"
else
  echo ">> WARNING: no updater at $UPD_APP; packaging toolchain only" >&2
fi
sh "$SHIPYARD_SCRIPTS/stage_product.sh" "$@" >&2

comp="$out/golang-$product-component.pkg"
rm -f "$comp"
sh "$SHIPYARD_SCRIPTS/build_component_pkg.sh" --root "$root" --identifier "dev.mavergreen.golang.$product" \
  --version "$PKG_VERSION" --install-location / --scripts "$scr" --out "$comp" >&2

if [ "$variant" = native ]; then
  # spec: PORT.md, the build chain -- install resources: the welcome text with the line's numbers filled in (sed to a new file, never -i), and Go's license
  res="$out/resources"
  rm -rf "$res"
  mkdir -p "$res"
  sed -e "s/@GO_MINOR@/$gominor/g" -e "s/@GO_LINE@/$GO_LINE/g" "$PORT_DIR/resources/Welcome.html" > "$res/Welcome.html"
  [ -f "$root$prefix/LICENSE" ] && cp "$root$prefix/LICENSE" "$res/LICENSE.txt"
  lic=""
  [ -f "$res/LICENSE.txt" ] && lic="--license LICENSE.txt"
  # shellcheck disable=SC2086
  sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier "dev.mavergreen.golang.$product" --title "$title" \
    --component "$comp" --out "$pkg" --resources "$res" --welcome Welcome.html $lic --host-arch x86_64 --require-scripts >&2
else
  sh "$SHIPYARD_SCRIPTS/set_install_floor.sh" --identifier "dev.mavergreen.golang.$product" --title "$title" \
    --component "$comp" --out "$pkg" --min-os "$CROSS_MIN_OS" --host-arch arm64 --require-scripts >&2
fi
rm -f "$comp"   # intermediate: only the floored product archive ships

# spec: PORT.md, the build chain -- the standalone archive: the same staged root, the product's tree alone, for a user who unpacks it
#       anywhere (stage_standalone.sh). The cross tree's SDKs -> ../sdk109/SDKs link stays the pkg's: sdk109 is a declared require and
#       the wrapper finds the SDK itself, so the archive is staged from a copy of the product tree without that link, leaving the pkg
#       root as it was. check-standalone-archive.sh judges it against the staged manifest, whose requires the wrappers may name, and
#       the line's INGREDIENTS.md, whose standalone-text deviations excuse crypto/x509's CA-bundle defaults (PORT.md invariant 7).
#       It runs after build_component_pkg.sh, which normalises the root's modes, so the archive's modes are the pkg's.
archive="$out/$product-$PKG_VERSION-macos-$arch.tar.gz"
rm -f "$archive"
if [ "$variant" = native ]; then
  saroot="$root"
else
  saroot="$WORK/standalone-$variant"
  # spec: build/package.sh -- the filtered copy never outlives this run, whether stage_standalone.sh succeeds or not
  trap 'rm -rf "$saroot"' EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  rm -rf "$saroot"
  mkdir -p "$saroot$prefix"
  # spec: build/package.sh -- cp -p keeps the normalised modes build_component_pkg.sh gave the root; an unpacking tar would apply this umask
  cp -pRP "$root$prefix/." "$saroot$prefix/"
  rm -f "$saroot$prefix/SDKs"
fi
sh "$SHIPYARD_SCRIPTS/stage_standalone.sh" "$saroot" "$product" "$PKG_VERSION" "$arch" "$archive" >&2
if [ "$saroot" != "$root" ]; then rm -rf "$saroot"; trap - EXIT HUP INT TERM; fi
sh "$SHIPYARD_SCRIPTS/check-standalone-archive.sh" --plist "$root$prefix/mavergreen.plist" --repo "$LINE_ROOT" "$archive" >&2 \
  || die "check-standalone-archive.sh refused $archive"

# spec: PORT.md, the build chain -- what this variant was built FROM; conformance compares the native and cross records. The built_* keys are
#       the versions c-toolchain.sh actually used; arch is the one read from the executables above.
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$out/build-info-$variant.txt" \
  variant="$variant" arch="$arch" prefix="$prefix" \
  go_version="$GO_VERSION" go_line="$GO_LINE" pkg_version="$PKG_VERSION" port_version="$(tr -d '[:space:]' < "$PORT_DIR/UPSTREAM_VERSION")" \
  recaulk_version="$RECAULK_VERSION" ca_sha256="$CA_SHA256" clang22_version="$CLANG22_VERSION" \
  $(sed -n 's/^\([a-z0-9]*\)=\(.*\)$/built_\1=\2/p' "$WORK/cc/versions")
echo "$archive"
echo "$pkg"
