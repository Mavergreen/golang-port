#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/package.sh: the native or cross toolchain, staged by build-native.sh or build-cross.sh, as a .pkg.
#       usage: LINE_ROOT=<line checkout> [UPD_APP=<updater .app>] [SOURCE_DATE_EPOCH=<n>] sh build/package.sh native|cross
#       Writes $WORK/out/golang-$GO_VERSION-<variant>-mavericks.<N>.pkg and build-info-<variant>.txt; prints the pkg's path last.
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

# spec: build/package.sh header -- the manifest goes into a copy; ._* entries from any host's tar never ship
root="$WORK/pkgroot-$variant"
rm -rf "$root"
mkdir -p "$root"
( cd "$src" && tar -cf - . ) | ( cd "$root" && tar -xf - )
find "$root" -name '._*' -exec rm -rf {} + 2>/dev/null || true

# spec: PORT.md, the build chain -- the shipped wrappers call clang22 (clang22-cross for the cross pkg), so the installer requires it; the
#       cross pkg also needs Longboat for 'longboat sdk install 10.9' and the SDK it installs. Every darwin/amd64 link is external
#       (GO_EXTLINK_ENABLED), pure-Go programs included, so clang22 is needed by every user.
scr="$out/pkg-scripts-$variant"
rm -rf "$scr"
set -- --stage "$root" --product "$product" --name "$name" --group go --line "$line" --version "$PKG_VERSION" \
  --exclude "bin/$wrapper" --requires "$req" --scripts-out "$scr"
[ "$variant" = cross ] && set -- "$@" --requires "longboat>=20261019.1" --requires sdk109
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

# spec: PORT.md, the build chain -- what this variant was built FROM; conformance compares the native and cross records. The built_* keys are
#       the versions c-toolchain.sh actually used, so a dev build whose clang22 or Recaulk drifted from the pins says so.
if [ "$variant" = native ]; then arch=x86_64; else arch=arm64; fi
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$out/build-info-$variant.txt" \
  variant="$variant" arch="$arch" prefix="$prefix" \
  go_version="$GO_VERSION" go_line="$GO_LINE" pkg_version="$PKG_VERSION" port_version="$(tr -d '[:space:]' < "$PORT_DIR/UPSTREAM_VERSION")" \
  recaulk_version="$RECAULK_VERSION" ca_sha256="$CA_SHA256" clang22_version="$CLANG22_VERSION" \
  $(sed -n 's/^\([a-z0-9]*\)=\(.*\)$/built_\1=\2/p' "$WORK/cc/versions")
echo "$pkg"
