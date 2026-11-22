#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/build-updater.sh: the Sparkle updater for one product, built with clang22 on any host through
#       shipyard's MavericksSparkle (mavericks_add_updater_app), configured the way the conventions skill's "Sparkle updater" says:
#       MavericksToolchain.cmake, clang22 as the ObjC compiler with an explicit target, --no-default-config, -fuse-ld=lld.
#       usage: LINE_ROOT=<line checkout> [CMAKE=<cmake>] sh build/build-updater.sh native|cross
#       Prints the app: $MAVERICKS_BUILD_ROOT/golang-updater[-cross]/go<LINE>[-cross]-updater.app (build/package.sh's UPD_APP default).
#       native: x86_64, minos 10.9, the 10.9 SDK. cross: arm64, minos 11.0; its SDK comes from shipyard's MavericksToolchain.cmake (fetch_sdk.sh's cache), not from sdk113.
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
variant="${1:-}"
case "$variant" in
  native) dirname=golang-updater; short_suffix=""; arch=x86_64; floor=10.9;;
  cross)  dirname=golang-updater-cross; short_suffix="-cross"; arch=arm64; floor=11.0;;
  *) echo "usage: LINE_ROOT=<line> build-updater.sh native|cross" >&2; exit 2 ;;
esac
. "$PORT_DIR/build/env.sh" || exit $?
die() { echo "build-updater.sh: $*" >&2; exit 1; }

sh "$PORT_DIR/build/c-toolchain.sh" > /dev/null || exit $?
# spec: PORT.md, the build chain -- the wrapper's own paths, read the way every build script reads them (toolchain-lib.sh).
TL_NAME=build-updater.sh
. "$PORT_DIR/build/toolchain-lib.sh"
cc_prefix="$(tl_cc_var cc_prefix)"
[ -x "$cc_prefix/bin/clang" ] || die "no clang22 at $cc_prefix (c-toolchain.sh should have refused)"

# spec: PORT.md, the build chain -- the CMake that configures against shipyard is its own (shipyard-cmake), else any cmake with MavericksShipyard_DIR
#       pointing at the directory holding MavericksToolchain.cmake, which is the parent of $SHIPYARD_SCRIPTS.
shipyard_dir="$(cd "$SHIPYARD_SCRIPTS/.." && pwd)"
[ -f "$shipyard_dir/MavericksToolchain.cmake" ] || die "no MavericksToolchain.cmake in $shipyard_dir -- shipyard's scripts dir is $SHIPYARD_SCRIPTS"
CMAKE="${CMAKE:-$(command -v shipyard-cmake || echo cmake)}"
command -v "$CMAKE" > /dev/null 2>&1 || die "no cmake ($CMAKE) -- install shipyard (shipyard-cmake) or cmake, or set CMAKE"

root="$MAVERICKS_BUILD_ROOT/$dirname"
rm -rf "$root"
mkdir -p "$root"

# spec: PORT.md, the build chain -- the updater is built at the line's VERSION; before a release writes one, at the computed auto version env.sh holds.
version_file="$LINE_ROOT/VERSION"
if [ ! -f "$version_file" ]; then
  version_file="$root/VERSION"
  printf '%s\n' "$PKG_VERSION" > "$version_file"
fi

# spec: PORT.md, the build chain -- the compat guard reads the built Mach-O with clang22's tools, since a Linux host has none of its own.
OTOOL="$cc_prefix/bin/llvm-otool"; LIPO="$cc_prefix/bin/llvm-lipo"
NM="$cc_prefix/bin/llvm-nm"; STRINGS="$cc_prefix/bin/llvm-strings"
export OTOOL LIPO NM STRINGS

"$CMAKE" -S "$PORT_DIR" -B "$root/build" -DMavericksShipyard_DIR="$shipyard_dir" \
  -DMAVGO_VARIANT="$variant" -DMAVGO_VERSION_FILE="$version_file" \
  -DCMAKE_TOOLCHAIN_FILE="$shipyard_dir/MavericksToolchain.cmake" -DCMAKE_OSX_ARCHITECTURES="$arch" \
  -DCMAKE_OBJC_COMPILER="$cc_prefix/bin/clang" -DCMAKE_OBJC_COMPILER_TARGET="$arch-apple-macos$floor" \
  -DCMAKE_OBJC_FLAGS=--no-default-config -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld >&2 \
  || die "the $variant updater did not configure"
"$CMAKE" --build "$root/build" -v >&2 || die "the $variant updater did not build"

app="go$GO_LINE$short_suffix-updater.app"
[ -d "$root/build/$app" ] || die "the build left no $root/build/$app"
cp -R "$root/build/$app" "$root/$app"
echo "$root/$app"
