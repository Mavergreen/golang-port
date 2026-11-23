#!/bin/sh
# platform: macOS-only -- runs the unpacked go; without an archive, or on a host that cannot run its arch, it skips (77)
# spec: PORT.md, the build chain -- the standalone archive, unpacked where no pkg put it, is a working toolchain: build/package.sh's
#       go1NN[-cross]-<version>-macos-<arch>.tar.gz, unpacked under a directory with a space, its bin/ first on PATH. go version and
#       go env GOROOT and CC name the unpacked copy (CC through port patch 0020), and a pure-Go and a cgo hello build through that
#       copy's wrapper, each an x86_64 program stamped minos 10.9. They run where the host is x86_64 (the 10.9 box); on an arm64 host
#       (the cross archive's) they are inspected, never run, as modern-smoke does. The line's CI calls it: on-target for the native
#       archive, modern-smoke for the cross archive.
#       usage: sh tests/standalone-smoke.sh ARCHIVE          (or STANDALONE_ARCHIVE=<archive>)
#       Needs what the archive requires: clang22 (clang22-cross for the cross archive) and sdk109, at /usr/local/mavergreen or at
#       MAVERGREEN_CLANG22 / MAVERGREEN_CLANG22_CROSS / MAVERGREEN_SDK109; Mach-O is read with that clang's llvm-otool, or OTOOL.
here=$(cd "$(dirname "$0")/.." && pwd)
archive="${1:-${STANDALONE_ARCHIVE:-}}"
[ -n "$archive" ] && [ -f "$archive" ] \
  || { echo "give a built go1NN[-cross]-<version>-macos-<arch>.tar.gz (argument or STANDALONE_ARCHIVE) -- skipping"; exit 77; }
fail() { echo "FAIL: $*"; exit 1; }

b="${archive##*/}"
case "$b" in
  *-macos-x86_64.tar.gz) arch=x86_64 ;;
  *-macos-arm64.tar.gz) arch=arm64 ;;
  *) fail "$b is not named <short>-<version>-macos-<x86_64|arm64>.tar.gz" ;;
esac
top="${b%-macos-$arch.tar.gz}"
short="$(printf '%s\n' "$top" | sed 's/-[0-9].*//')"
case "$short" in
  go[0-9]*-cross) wrapper=mavericks-cross-clang; cl="${MAVERGREEN_CLANG22_CROSS:-/usr/local/mavergreen/clang22-cross}" ;;
  go[0-9]*) wrapper=mavericks-clang; cl="${MAVERGREEN_CLANG22:-/usr/local/mavergreen/clang22}" ;;
  *) fail "$b is not a go1NN or go1NN-cross archive" ;;
esac
case "$arch" in x86_64) goarch=amd64 ;; *) goarch=arm64 ;; esac
host="$(uname -s) $(uname -m)"
[ "$host" = "Darwin $arch" ] || { echo "this host ($host) does not run the archive's $arch go natively -- skipping"; exit 77; }
otool="${OTOOL:-$cl/bin/llvm-otool}"
[ -x "$otool" ] || fail "no $otool to read the programs with -- install ${cl##*/}, or set OTOOL"

t=$(mktemp -d "${TMPDIR:-/tmp}/standalone-smoke.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'chmod -R u+w "$t" 2>/dev/null; rm -rf "$t"' EXIT
# spec: tests/standalone-smoke.sh -- the physical spelling (a Mac's /var is /private/var), which is how go reports its own GOROOT
t=$(cd "$t" && pwd -P)
u="$t/un packed"
mkdir "$u"
tar -xzf "$archive" -C "$u" || fail "cannot unpack $archive"
G="$u/$top"
[ -x "$G/bin/go" ] || fail "no $top/bin/go in $b"

unset GOROOT GOOS GOARCH CGO_ENABLED CC CXX GO_EXTLINK_ENABLED GODEBUG GOENV
PATH="$G/bin:$PATH" GOCACHE="$t/gocache" GOPATH="$t/gopath" GOENV="$t/goenv" GOFLAGS= GOTOOLCHAIN=local GOPROXY=off
export PATH GOCACHE GOPATH GOENV GOFLAGS GOTOOLCHAIN GOPROXY

[ "$(command -v go)" = "$G/bin/go" ] || fail "go on PATH is $(command -v go), not the unpacked $G/bin/go"
v="$(go version)" || fail "the unpacked go does not run"
echo "$v"
case "$v" in "go version go1."*" darwin/$goarch") ;; *) fail "go version should be a go1.N release ending darwin/$goarch: $v" ;; esac
gr="$(go env GOROOT)"
[ "$gr" = "$G" ] || fail "go env GOROOT is '$gr', want the unpacked $G"
echo "ok   go env GOROOT: $gr"
# spec: PORT.md, 0020-cmd-go-goroot-relative-cc.patch -- go.env's relative CC resolves against GOROOT; a path with a space comes back quoted
cc="$(go env CC)"
[ "$cc" = "'$G/bin/$wrapper'" ] || fail "go env CC is $cc, want the unpacked copy's wrapper '$G/bin/$wrapper'"
echo "ok   go env CC: $cc"

minos_of() { "$otool" -l "$1" | awk '/LC_VERSION_MIN_MACOSX/ { f = 1 } f && / version / { print $2; exit }'; }
arch_of() { "$otool" -hv "$1" | awk '$1 ~ /^MH_MAGIC/ { print $2; exit }'; }
mkdir -p "$t/pure" "$t/cgo"
cat > "$t/pure/main.go" <<'GOEOF'
package main

import (
	"fmt"
	"time"
)

// time.Now reaches clock_gettime, which 10.9's libSystem lacks: Recaulk must be linked in.
func main() { fmt.Println("standalone pure-go ok", time.Now().Year() > 2000) }
GOEOF
cp "$here/tests/hello-cgo/main.go" "$t/cgo/main.go"
gomod="go $(printf '%s\n' "$v" | sed -n 's/^go version go\(1\.[0-9]*\).*/\1/p')"
printf 'module pure\n\n%s\n' "$gomod" > "$t/pure/go.mod"
printf 'module hellocgo\n\n%s\n' "$gomod" > "$t/cgo/go.mod"
for p in pure cgo; do
  case "$p" in pure) cgo=0 ;; *) cgo=1 ;; esac
  (cd "$t/$p" && GOOS=darwin GOARCH=amd64 CGO_ENABLED="$cgo" go build -x -o "$t/$p.bin" .) > "$t/$p.log" 2>&1 \
    || { tail -30 "$t/$p.log"; fail "$p: go build failed"; }
  # spec: tests/standalone-smoke.sh -- every darwin/amd64 link is external, so even the pure-Go build runs the unpacked copy's wrapper
  grep -qF "$G/bin/$wrapper" "$t/$p.log" || { tail -30 "$t/$p.log"; fail "$p: the build never ran $G/bin/$wrapper"; }
  a="$(arch_of "$t/$p.bin")"; m="$(minos_of "$t/$p.bin")"
  [ "$a" = X86_64 ] || fail "$p: the program is '$a', want X86_64"
  [ "$m" = 10.9 ] || fail "$p: minos is '${m:-none}', want 10.9"
  if [ "$arch" = x86_64 ]; then
    out="$("$t/$p.bin" 2>&1)" || fail "$p: does not run: $out"
    echo "ok   $p: built through the unpacked wrapper, x86_64, minos 10.9; runs: $out"
  else
    echo "ok   $p: built through the unpacked wrapper, x86_64, minos 10.9; not run on this $arch host"
  fi
done
echo "PASS: standalone-smoke ($b)"
