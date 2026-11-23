#!/bin/sh
# platform: host-agnostic -- the Linux half of provisioning; it refuses Darwin itself, where install@v1 `products:` and Longboat install
# spec: PORT.md, the build chain -- build/provision-linux.sh, interim until install@v1 `products:` installs on Linux (shipyard's
#       install-products.sh installs with macOS's `installer`).
#       Exit: delete this script when shipyard's install@v1 `products:` learns Linux assets; a line's Linux job then names its products to install@v1.
#       usage: sudo -E sh build/provision-linux.sh [--root DIR] clang22@<version> sdk109[@<longboat tag>] recaulk@<version>
#       A line passes its pins from components/*/version. Each product lands where its macOS pkg installs it,
#       DIR/usr/local/mavergreen/<short>/ (DIR defaults to /), with the mavergreen.plist that install leaves:
#         clang22  its linux-x86_64 archive (fetch_product_tar.sh); the plist out of the release pkg its clang22.xml names.
#         sdk109   the pinned 10.9 SDK (fetch_sdk.sh) at SDKs/MacOSX10.9.sdk; the plist rendered by stage_product.sh with the
#                  arguments `longboat sdk install 10.9` gives it, versioned by the longboat release named, else longboat's
#                  latest: no release ships an sdk109 pkg, Longboat builds it on the Mac it installs on.
#         recaulk  its release pkg's component tree (fetch_product_pkg.sh), plist included.
#       A product whose installed plist already has the wanted version is kept, and said so; a bare sdk109 keeps any version.
#       Needs SHIPYARD_SCRIPTS. Exit 1 on a failure, and on Darwin; 2 on a usage error. MAVERGREEN_RELEASES, MAVERGREEN_PKG_CACHE,
#       MAVERGREEN_TAR_CACHE and MAVERICKS_SDK_* pass through to shipyard's fetchers (the tests serve file://).
#       MAVERGREEN_UNAME_S stands in for `uname -s`, for tests only.
set -eu
usage() { echo "usage: sudo -E sh build/provision-linux.sh [--root DIR] clang22@<version> sdk109[@<longboat tag>] recaulk@<version>" >&2; exit 2; }
die() { echo "provision-linux.sh: $*" >&2; exit 1; }
say() { echo "provision-linux.sh: $*" >&2; }
# spec: build/provision-linux.sh -- Darwin refuses first, whatever the arguments
[ "${MAVERGREEN_UNAME_S:-$(uname -s)}" != Darwin ] || die "this is Linux's interim provisioner; on macOS install the products with install@v1 \`products:\` or Longboat (sudo longboat sdk install 10.9; sudo installer -pkg <product>.pkg -target /)"

ROOT=/
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] && [ -n "$2" ] || usage; ROOT=$2; shift 2 ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || usage
for p in "$@"; do
  case "$p" in
    clang22@any|recaulk@any) echo "provision-linux.sh: '$p' must name its release: clang22 and recaulk are pinned" >&2; usage ;;
    clang22@*|recaulk@*|sdk109@*) t="${p#*@}" ;;
    sdk109) t=any ;;
    *) echo "provision-linux.sh: '$p' is not clang22@<version>, sdk109[@<longboat tag>] or recaulk@<version>" >&2; usage ;;
  esac
  case "$t" in ''|.|..|latest|*[!A-Za-z0-9._+-]*) echo "provision-linux.sh: '$p' names no release tag" >&2; usage ;; esac
done

SY="${SHIPYARD_SCRIPTS:-}"
[ -n "$SY" ] && [ -f "$SY/fetch_product_tar.sh" ] || die "SHIPYARD_SCRIPTS names no shipyard scripts directory (have: '${SY}'); install shipyard and export it"

MG="${ROOT%/}/usr/local/mavergreen"
mkdir -p "$MG" || die "cannot make $MG"
work="$(mktemp -d "$MG/.provision-linux.XXXXXX")" || die "cannot make a work directory in $MG"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# spec: build/c-toolchain.sh -- the version a product reports is its mavergreen.plist's <key>version</key> string
plist_version() {
  sed -n '/<key>version<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$1/mavergreen.plist" 2>/dev/null | sed -n 1p
}

# spec: build/provision-linux.sh -- place <short> <staged tree> <version>: the staged tree replaces DIR's, whole
place() {
  [ -f "$2/mavergreen.plist" ] || die "$1: the staged tree has no mavergreen.plist"
  _pv="$(plist_version "$2")"
  [ "$_pv" = "$3" ] || die "$1: the release's mavergreen.plist says version '$_pv', not $3"
  # spec: build/provision-linux.sh -- the old tree moves aside before the new one moves in, so an interruption never leaves the product absent
  _old=""
  if [ -e "$MG/$1" ] || [ -L "$MG/$1" ]; then
    _old="$work/old-$1"
    mv "$MG/$1" "$_old" || die "$1: cannot move the old tree at $MG/$1 aside"
  fi
  if ! mv "$2" "$MG/$1"; then
    [ -z "$_old" ] || mv "$_old" "$MG/$1"
    die "$1: cannot move the staged tree to $MG/$1"
  fi
  [ -z "$_old" ] || rm -rf "$_old"
  say "installed $1 $3 at $MG/$1"
}

# spec: build/provision-linux.sh -- pkg_plist <short> <tag> <out>: the mavergreen.plist the release pkg installs, picked as
#       install-products.sh picks it: the pkg <short>.xml names, the component whose identifier the registry gives
pkg_plist() {
  _repo="$(sh "$SY/product-name.sh" repo "$1")" || die "$1: the registry has no repo for it"
  _id="$(sh "$SY/product-name.sh" identifier "$1")" || die "$1: the registry has no identifier for it"
  _feed="$(sh "$SY/product-name.sh" feed "$1")" || die "$1: the registry has no feed for it"
  _w="$work/plist-$1"; mkdir -p "$_w"
  _xml="$(sh "$SY/fetch-release-pkg.sh" "$_repo" "$2" "${_feed##*/}" "$_w")" || die "$1 $2: no verified ${_feed##*/}"
  _u="$(awk '{ s = s $0 " " }
    END { while (match(s, /<enclosure[^>]*>/)) {
            e = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
            if (match(e, /url="[^"]*"/)) print substr(e, RSTART + 5, RLENGTH - 6) } }' "$_xml" | sort -u)"
  case "$_u" in ''|*"
"*) die "$1 $2: ${_feed##*/} does not name exactly one pkg" ;; esac
  _cache="${MAVERGREEN_PKG_CACHE:-$HOME/Library/Caches/mavergreen-pkgs}/$_repo/$2"
  _pkg="$(sh "$SY/fetch-release-pkg.sh" "$_repo" "$2" "${_u##*/}" "$_cache")" || die "$1 $2: no verified ${_u##*/}"
  _st="$(sh "$SY/fetch_stevedore.sh")" || die "no stevedore to expand $_pkg with"
  "$_st" expand "$_pkg" "$_w/x" > /dev/null || die "$1 $2: cannot expand $_pkg"
  _m="$(grep -lF "identifier=\"$_id\"" "$_w"/x/*/PackageInfo 2>/dev/null || :)"
  [ "$(printf '%s\n' "$_m" | grep -c .)" = 1 ] || die "$1 $2: expected one component $_id in $_pkg"
  mkdir "$_w/p"
  ( cd "$_w/p" && gzip -dc "$(dirname "$_m")/Payload" | cpio -id --quiet "*usr/local/mavergreen/$1/mavergreen.plist" ) 2>/dev/null \
    || die "$1 $2: cannot unpack the Payload of $_id"
  mv "$_w/p/usr/local/mavergreen/$1/mavergreen.plist" "$3" 2>/dev/null || die "$1 $2: $_id installs no usr/local/mavergreen/$1/mavergreen.plist"
  rm -rf "$_w"
}

clang22() {
  sh "$SY/fetch_product_tar.sh" clang22 "$1" "$work/clang22" > /dev/null || die "clang22 $1: no verified linux-x86_64 archive"
  # spec: build/provision-linux.sh -- fetch_product_tar.sh's cache stamp is no file the pkg installs
  rm -f "$work/clang22/.mavergreen-archive-sha256"
  [ -x "$work/clang22/bin/clang" ] || die "clang22 $1: the archive has no bin/clang"
  pkg_plist clang22 "$1" "$work/clang22/mavergreen.plist"
  place clang22 "$work/clang22" "$1"
  # spec: build/c-toolchain.sh -- it refuses a clang22 without the three tools Go's darwin link asks the wrapper for
  for _t in dsymutil llvm-strip llvm-ar; do
    [ -x "$MG/clang22/bin/$_t" ] || say "warning: clang22 $1 has no bin/$_t, so build/c-toolchain.sh will refuse it; clang22 22.1.8-mavericks.26 ships it"
  done
}

recaulk() {
  sh "$SY/fetch_product_pkg.sh" recaulk "$1" "$work/recaulk" > /dev/null || die "recaulk $1: no verified pkg"
  [ -f "$work/recaulk/lib/librecaulk.a" ] || die "recaulk $1: the pkg has no lib/librecaulk.a"
  place recaulk "$work/recaulk" "$1"
}

sdk109() {
  _sdk="$(sh "$SY/fetch_sdk.sh")" || die "sdk109: fetch_sdk.sh fetched no SDK"
  [ "${_sdk##*/}" = MacOSX10.9.sdk ] || die "sdk109: fetch_sdk.sh gave $_sdk, not a MacOSX10.9.sdk"
  _tag=$1
  if [ "$_tag" = any ]; then
    _tag="$(. "$SY/mavericks_fetch.sh" && shipyard_latest_tag "$(sh "$SY/product-name.sh" repo sdk109)")" || die "sdk109: no latest longboat release to version it by"
  fi
  _s="$work/sdkstage"
  mkdir -p "$_s/usr/local/mavergreen/sdk109/SDKs"
  cp -RP "$_sdk" "$_s/usr/local/mavergreen/sdk109/SDKs/MacOSX10.9.sdk" || die "sdk109: cannot copy $_sdk"
  # spec: build/provision-linux.sh -- the arguments longboat's lb_install_pkg passes for 10.9 ("<lb_sdk_name 10.9> SDK", its own version)
  sh "$SY/stage_product.sh" --stage "$_s" --product sdk109 --name "Mac OS X 10.9 SDK" --version "$_tag" \
    --scripts-out "$work/sdkscripts" > /dev/null || die "sdk109: stage_product.sh could not render its mavergreen.plist"
  place sdk109 "$_s/usr/local/mavergreen/sdk109" "$_tag"
}

for p in "$@"; do
  s="${p%%@*}"
  case "$p" in *@*) want="${p#*@}" ;; *) want=any ;; esac
  have="$(plist_version "$MG/$s")"
  if [ -n "$have" ] && { [ "$have" = "$want" ] || [ "$want" = any ]; }; then
    say "kept $s $have at $MG/$s"
    continue
  fi
  [ -z "$have" ] || say "replacing $s $have at $MG/$s with $want"
  "$s" "$want"
done
