#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/toolchain-lib.sh: what build-native.sh and build-cross.sh share. Sourced after env.sh and
#       build-builder.sh, so $WORK/go is the builder, $WORK/builder.tools its tool list and $WORK/cc/vars the build wrapper's paths.

tl_die() { echo "${TL_NAME:-toolchain-lib.sh}: $*" >&2; exit 1; }

# spec: PORT.md, the build chain -- tl_cc_var NAME: a path the build wrapper was written with (cc_prefix, sdk, recaulk), from
#       c-toolchain.sh's $WORK/cc/vars, so the products ship the Recaulk the build linked and read Mach-O with the clang22 it used.
tl_cc_var() {
  [ -f "$WORK/cc/vars" ] || tl_die "no $WORK/cc/vars; run build/c-toolchain.sh"
  _tw="$( . "$WORK/cc/vars" && eval "printf %s \"\${$1:-}\"")"
  [ -n "$_tw" ] || tl_die "no $1 in $WORK/cc/vars; run build/c-toolchain.sh"
  printf '%s' "$_tw"
}

# spec: PORT.md, the build chain -- tl_go_env: nothing from the caller's environment steers `go install`: the target, cgo, the compiler,
#       GOFLAGS, the user's go env file and toolchain switching are all set here or Go's defaults. Each variable that was set is named.
tl_go_env() {
  _tl_unset=""
  for _tl_v in CC CXX CC_FOR_TARGET CXX_FOR_TARGET GOOS GOARCH GOHOSTOS GOHOSTARCH GOROOT_FINAL GOFLAGS GOAMD64 GOARM64 \
               GOEXPERIMENT GOFIPS140 GOBIN GO_EXTLINK_ENABLED GO_LDFLAGS $(env | sed -n 's/^\(CGO_[A-Za-z0-9_]*\)=.*/\1/p'); do
    if [ -n "$(eval "printf %s \"\${$_tl_v+set}\"")" ]; then _tl_unset="$_tl_unset $_tl_v"; unset "$_tl_v"; fi
  done
  [ -z "$_tl_unset" ] || echo "$TL_NAME: unset$_tl_unset so the build cannot inherit them" >&2
  GOROOT="$WORK/go" GOCACHE="$WORK/.gocache" GOENV=off GOTOOLCHAIN=local GOPROXY=off
  PATH="$WORK/cc/bin:$PATH"
  export GOROOT GOCACHE GOENV GOTOOLCHAIN GOPROXY PATH
}

# spec: PORT.md, the build chain -- tl_stage GOOS GOARCH DEST: the shipped GOROOT, copied out of $WORK/go; staging itself changes
#       nothing there (on a darwin/amd64 host the native `go install` before it has already replaced the builder's own binaries). Every
#       top-level file and the patched source (std ships as source); pkg/include; bin/go and bin/gofmt for the target; and in
#       pkg/tool only the builder's own tools. No host binary is copied: a cross-built target's binaries come from bin/<os>_<arch>
#       (where `go install` puts them), and only a host that IS the target takes bin/ itself.
tl_stage() {
  _ts_t="$1_$2" _ts_dest="$3" _ts_src="$WORK/go"
  [ -s "$WORK/builder.tools" ] || tl_die "no $WORK/builder.tools; run build/build-builder.sh"
  rm -rf "$_ts_dest"
  mkdir -p "$_ts_dest/bin" "$_ts_dest/pkg/tool/$_ts_t"
  _ts_top="$(cd "$_ts_src" && LC_ALL=C ls -A | grep -v -x -e bin -e pkg)"
  ( cd "$_ts_src" && tar -cf - $_ts_top ) | ( cd "$_ts_dest" && tar -xf - )
  ( cd "$_ts_src/pkg" && tar -cf - include ) | ( cd "$_ts_dest/pkg" && tar -xf - )
  if [ -d "$_ts_src/bin/$_ts_t" ]; then
    _ts_bin="$_ts_src/bin/$_ts_t"
  else
    _ts_host="$("$_ts_src/bin/go" env GOHOSTOS)_$("$_ts_src/bin/go" env GOHOSTARCH)"
    [ "$_ts_host" = "$_ts_t" ] || tl_die "no $_ts_src/bin/$_ts_t, and the host is $_ts_host, not $_ts_t: go install did not build the target"
    _ts_bin="$_ts_src/bin"
  fi
  for _ts_b in go gofmt; do
    [ -f "$_ts_bin/$_ts_b" ] || tl_die "go install left no $_ts_bin/$_ts_b"
    cp -p "$_ts_bin/$_ts_b" "$_ts_dest/bin/$_ts_b"
  done
  while read -r _ts_tool; do
    [ -f "$_ts_src/pkg/tool/$_ts_t/$_ts_tool" ] || tl_die "go install left no pkg/tool/$_ts_t/$_ts_tool"
    cp -p "$_ts_src/pkg/tool/$_ts_t/$_ts_tool" "$_ts_dest/pkg/tool/$_ts_t/$_ts_tool"
  done < "$WORK/builder.tools"
}

# spec: PORT.md, the build chain -- tl_macho ARCH MINOS SDK FILE...: each FILE is a thin ARCH Mach-O (llvm-lipo -info) and, when MINOS is
#       not empty, records that minimum OS and SDK (llvm-otool -l: LC_BUILD_VERSION or LC_VERSION_MIN_MACOSX). Prints
#       "<file> <arch> minos <m> sdk <s>" per file on stderr.
tl_macho() {
  _tm_arch=$1 _tm_min=$2 _tm_sdk=$3; shift 3
  _tm_cl="$(tl_cc_var cc_prefix)"
  [ -x "$_tm_cl/bin/llvm-otool" ] && [ -x "$_tm_cl/bin/llvm-lipo" ] || tl_die "no llvm-otool/llvm-lipo in $_tm_cl/bin"
  for _tm_f in "$@"; do
    _tm_a="$("$_tm_cl/bin/llvm-lipo" -info "$_tm_f" 2>/dev/null | sed -n 's/^Non-fat file: .* is architecture: \([^ ]*\).*$/\1/p')"
    [ "$_tm_a" = "$_tm_arch" ] || tl_die "$_tm_f is not a thin $_tm_arch Mach-O (llvm-lipo -info: $("$_tm_cl/bin/llvm-lipo" -info "$_tm_f" 2>&1))"
    _tm_v="$("$_tm_cl/bin/llvm-otool" -l "$_tm_f" | awk '
      $1 == "cmd" { c = $2; next }
      c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { m = $2 }
      c == "LC_BUILD_VERSION" && $1 == "minos" { m = $2 }
      (c == "LC_VERSION_MIN_MACOSX" || c == "LC_BUILD_VERSION") && $1 == "sdk" { s = $2 }
      END { printf "%s %s", m, s }')"
    echo "$TL_NAME: ${_tm_f##*/} $_tm_a minos ${_tm_v% *} sdk ${_tm_v#* }" >&2
    [ -z "$_tm_min" ] || [ "$_tm_v" = "$_tm_min $_tm_sdk" ] || tl_die "$_tm_f records minos/sdk '$_tm_v', want '$_tm_min $_tm_sdk' (internal-linked? see -linkmode=external)"
  done
}
