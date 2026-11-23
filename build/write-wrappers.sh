#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/write-wrappers.sh: writes the C compiler wrapper a product ships, the CC its go.env names.
#       usage: LINE_ROOT=<line checkout> sh build/write-wrappers.sh KIND DIR    writes DIR/bin/<wrapper>
#         native  mavericks-clang        $MAVERGREEN_CLANG22, else /usr/local/mavergreen/clang22 (the family compiler on 10.9)
#         cross   mavericks-cross-clang  $MAVERGREEN_CLANG22_CROSS, else /usr/local/mavergreen/clang22-cross (an arm64 Mac)
#         linux   mavericks-cross-clang  $MAVERGREEN_CLANG22, else /usr/local/mavergreen/clang22
#       Each finds Recaulk beside itself (<its dir>/../lib/librecaulk.a), so the toolchain works wherever it is put, adds the build
#       wrapper's flags (build/cc-wrapper.sh) against $MAVERGREEN_SDK109's 10.9 SDK (default /usr/local/mavergreen/sdk109), and fails
#       naming the product to install, and the override, when its compiler or the SDK is absent. MAVERGREEN_PREFIX relocates the
#       family prefix for tests only.
# spec: PORT.md, the build chain -- the cross wrapper's override is MAVERGREEN_CLANG22_CROSS, not MAVERGREEN_CLANG22: it needs the arm64
#       clang22-cross, another product, and one exported MAVERGREEN_CLANG22 (meant for an x86_64 clang22) must not steer both.
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
usage() { echo "usage: write-wrappers.sh native|cross|linux DIR" >&2; exit 2; }
[ $# -eq 2 ] && [ -n "$2" ] || usage
kind=$1 dir=$2
case "$kind" in native|cross|linux) ;; *) usage ;; esac
. "$PORT_DIR/build/env.sh" || exit $?
. "$PORT_DIR/build/cc-wrapper.sh"

MG="${MAVERGREEN_PREFIX:-/usr/local/mavergreen}"
# spec: PORT.md, the build chain -- every wrapper finds its own directory from $0 by expansion, not dirname, which a minimal PATH (/bin on
#       10.9) lacks, and Recaulk in ../lib beside it: the installed pkg's own lib/, or wherever the tree was unpacked or copied.
#       CDPATH is emptied for that cd: an exported CDPATH would send it elsewhere and make it print the directory.
#       MAVERGREEN_SDK109 names an sdk109 directory (the one holding SDKs/MacOSX10.9.sdk), as MAVERGREEN_CLANG22 names a clang22 one.
beside='case "$0" in */*) here="${0%/*}" ;; *) here=. ;; esac
recaulk="$(CDPATH= cd "$here/.." && pwd)/lib/librecaulk.a"'
sdk="sdk=\"\${MAVERGREEN_SDK109:-$MG/sdk109}/SDKs/MacOSX10.9.sdk\""
mac_sdk='no_sdk="sdk109 is not installed (no $sdk). Install it: sudo longboat sdk install 10.9 (github.com/Mavergreen/longboat), or set MAVERGREEN_SDK109 to an sdk109 directory"'
mkdir -p "$dir/bin"
case "$kind" in
  native)
    cc_wrapper "$dir/bin/mavericks-clang" "cc_prefix=\"\${MAVERGREEN_CLANG22:-$MG/clang22}\"
$sdk
$beside
no_clang=\"clang22 is not installed (no \$cc_prefix/bin/clang). Install it: sudo installer -pkg clang22-$CLANG22_VERSION.pkg -target / (github.com/Mavergreen/clang-22 releases), or set MAVERGREEN_CLANG22 to a clang22 directory\"
$mac_sdk" ;;
  cross)
    cc_wrapper "$dir/bin/mavericks-cross-clang" "cc_prefix=\"\${MAVERGREEN_CLANG22_CROSS:-$MG/clang22-cross}\"
$sdk
$beside
no_clang=\"clang22-cross is not installed (no \$cc_prefix/bin/clang). Install it: sudo installer -pkg clang22-cross-$CLANG22_VERSION.pkg -target / (github.com/Mavergreen/clang-22 releases), or set MAVERGREEN_CLANG22_CROSS to a clang22-cross directory\"
$mac_sdk" ;;
  linux)
    # spec: PORT.md, the build chain -- the linux archive's requires are install@v1 products:, so its messages name that, not a pkg.
    cc_wrapper "$dir/bin/mavericks-cross-clang" "cc_prefix=\"\${MAVERGREEN_CLANG22:-$MG/clang22}\"
$sdk
$beside
no_clang=\"clang22 is not installed (no \$cc_prefix/bin/clang). Install it: list clang22@$CLANG22_VERSION under install@v1 products: (it lands at /usr/local/mavergreen/clang22), or set MAVERGREEN_CLANG22 to a clang22 directory\"
no_sdk=\"sdk109 is not installed (no \$sdk). Install it: list sdk109@<any release> under install@v1 products:, or set MAVERGREEN_SDK109 to an sdk109 directory\"" ;;
esac
