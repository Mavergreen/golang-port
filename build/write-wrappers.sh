#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/write-wrappers.sh: writes the C compiler wrapper a product ships, the CC its go.env names.
#       usage: LINE_ROOT=<line checkout> sh build/write-wrappers.sh KIND DIR    writes DIR/bin/<wrapper>
#         native  mavericks-clang        /usr/local/mavergreen/clang22 (the family compiler on 10.9), Recaulk from $PREFIX/lib
#         cross   mavericks-cross-clang  /usr/local/mavergreen/clang22-cross (an arm64 Mac), Recaulk from $CROSS_PREFIX/lib
#         linux   mavericks-cross-clang  $MAVERGREEN_CLANG22, else /usr/local/mavergreen/clang22, Recaulk from the archive's own lib/
#       Each adds the build wrapper's flags (build/cc-wrapper.sh) against /usr/local/mavergreen/sdk109's 10.9 SDK, and fails naming
#       the product to install when its compiler or the SDK is absent. MAVERGREEN_PREFIX relocates the family prefix for tests only.
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
SDK="$MG/sdk109/SDKs/MacOSX10.9.sdk"
mac_sdk="no_sdk='sdk109 is not installed (no $SDK). Install it: sudo longboat sdk install 10.9 (github.com/Mavergreen/longboat)'"
mkdir -p "$dir/bin"
case "$kind" in
  native)
    cc_wrapper "$dir/bin/mavericks-clang" "cc_prefix='$MG/clang22'
sdk='$SDK'
recaulk='$PREFIX/lib/librecaulk.a'
no_clang='clang22 is not installed (no $MG/clang22/bin/clang). Install it: sudo installer -pkg clang22-$CLANG22_VERSION.pkg -target / (github.com/Mavergreen/clang-22 releases)'
$mac_sdk" ;;
  cross)
    cc_wrapper "$dir/bin/mavericks-cross-clang" "cc_prefix='$MG/clang22-cross'
sdk='$SDK'
recaulk='$CROSS_PREFIX/lib/librecaulk.a'
no_clang='clang22-cross is not installed (no $MG/clang22-cross/bin/clang). Install it: sudo installer -pkg clang22-cross-$CLANG22_VERSION.pkg -target / (github.com/Mavergreen/clang-22 releases)'
$mac_sdk" ;;
  linux)
    # spec: PORT.md, the build chain -- the linux archive can be extracted anywhere, so its Recaulk is found beside the wrapper, and
    #       clang22 may live outside the family prefix (MAVERGREEN_CLANG22). Its own directory comes from $0 by expansion, not
    #       dirname, which a minimal PATH (/bin on 10.9) lacks.
    cc_wrapper "$dir/bin/mavericks-cross-clang" "cc_prefix=\"\${MAVERGREEN_CLANG22:-$MG/clang22}\"
sdk='$SDK'
case \"\$0\" in */*) here=\"\${0%/*}\" ;; *) here=. ;; esac
recaulk=\"\$(cd \"\$here/..\" && pwd)/lib/librecaulk.a\"
no_clang=\"clang22 is not installed (no \$cc_prefix/bin/clang). Install it: install@v1 products: clang22@$CLANG22_VERSION (it lands at /usr/local/mavergreen/clang22), or set MAVERGREEN_CLANG22 to a clang22 directory\"
no_sdk='sdk109 is not installed (no $SDK). Install it: install@v1 products: sdk109'" ;;
esac
