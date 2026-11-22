#!/bin/sh
# platform: macOS-only -- runs in the 10.9 guest against the installed toolchain
# spec: PORT.md, the build chain -- the on-target suite: what only a real 10.9 box can prove about an installed go1NN. Run it in the
#       mavericks-vm guest after installing the line's native pkg (and clang22, which cgo and the external link need).
#       usage: GO_LINE=127 sh tests/on-target/run.sh        (GOROOT=<dir> overrides /usr/local/mavergreen/go$GO_LINE; GO_LINE is then
#              read from `go version`)
#       Covers: go version; crypto/x509's keychain-union and fallback tests; the pure-Go link (default, CGO_ENABLED=0 and a go test
#       binary all run); a cgo program that defines its own SecTrustEvaluateWithError; a cgo hello; both verifiers rejecting an
#       untrusted chain. Nothing here skips: a missing prerequisite is a failure, so the suite never passes by examining less.
#       Exits 0 only when every check passed.
set -eu
fail=0
bad() { echo "FAIL: $*"; fail=1; }
die() { echo "FAIL: $*"; exit 1; }

clang22="${MAVERGREEN_CLANG22:-/usr/local/mavergreen/clang22}"
for tool in llvm-nm llvm-otool; do
  [ -x "$clang22/bin/$tool" ] || die "no $clang22/bin/$tool -- install clang22 in the guest (sudo installer -pkg clang22-<version>.pkg -target /); this suite does not skip"
done

if [ -n "${GOROOT:-}" ]; then
  goroot="$GOROOT"
else
  [ -n "${GO_LINE:-}" ] || { echo "usage: GO_LINE=<126|127|...> sh tests/on-target/run.sh" >&2; exit 2; }
  goroot="/usr/local/mavergreen/go$GO_LINE"
fi
[ -x "$goroot/bin/go" ] || die "no go at $goroot/bin/go -- install the line's native pkg first; this suite does not skip"

here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/on-target.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
unset HTTPS_PROXY HTTP_PROXY ALL_PROXY GODEBUG GO_EXTLINK_ENABLED GOOS GOARCH CGO_ENABLED
export GOROOT="$goroot" PATH="$goroot/bin:$PATH" GOCACHE="$tmp/gocache" GOPATH="$tmp/gopath" GOFLAGS= GOTOOLCHAIN=local GOPROXY=off

# spec: on-target suite, check 1 -- go version: the line under test, built for this machine
ver="$(go version)" || die "go version failed"
echo "$ver"
minor="$(printf '%s\n' "$ver" | sed -n 's/^go version go1\.\([0-9][0-9]*\).*/\1/p')"
[ -n "$minor" ] || die "go version says '$ver', which is not a go1.N release"
: "${GO_LINE:=1$minor}"
[ "$GO_LINE" = "1$minor" ] || die "GO_LINE=$GO_LINE but $goroot/bin/go is Go 1.$minor"
printf '%s\n' "$ver" | grep -q ' darwin/amd64$' || bad "go version should end darwin/amd64: $ver"
gomod="go 1.$minor"

# spec: on-target suite, check 2 -- the keychain-union trust tests, run on the toolchain's own source (needs clang22: crypto/x509 links cgo-free, the test binary links through the wrapper)
out="$(go test crypto/x509 -run 'KeychainUnion|Fallback' -count=1 -v 2>&1)" || { printf '%s\n' "$out" | tail -40; bad "go test crypto/x509 failed"; }
skipped="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*--- SKIP: ' || true)"
[ -z "$skipped" ] || bad "tests skipped on the target (they must run here): $skipped"
passed="$(printf '%s\n' "$out" | grep -c '^--- PASS: Test[A-Za-z_]*KeychainUnion' || true)"
[ "$passed" -ge 27 ] || bad "expected >=27 KeychainUnion tests to pass, saw $passed -- did -run match nothing?"
for t in TestFallback TestFallbackPanic; do
  printf '%s\n' "$out" | grep -q "^--- PASS: $t " || bad "upstream $t did not pass"
done
echo "ok   crypto/x509: $passed KeychainUnion tests, TestFallback, TestFallbackPanic"

# spec: on-target suite, check 3 -- pure-go-link: a pure-Go program must be 10.9-safe -- external-linked through the wrapper (Recaulk, minos 10.9), not internal-linked
#       to Go's own floor with clock_gettime unresolved. Each build must run here.
mkdir -p "$tmp/pure"
cat > "$tmp/pure/main.go" <<'GOEOF'
package main

import (
	"fmt"
	"time"
)

// time.Now reaches clock_gettime, which 10.9's libSystem lacks: Recaulk must be linked in.
func main() { fmt.Println("pure-go ok", time.Now().Year() > 2000) }
GOEOF
cat > "$tmp/pure/main_test.go" <<'GOEOF'
package main

import "testing"

func TestPure(t *testing.T) {}
GOEOF
printf 'module purego\n\n%s\n' "$gomod" > "$tmp/pure/go.mod"
minos_of() { "$clang22/bin/llvm-otool" -l "$1" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/ version /{print $2; exit}'; }
pure_check() { # binary label
  if out="$("$1" 2>&1)"; then
    m="$(minos_of "$1")"
    if [ "$m" = 10.9 ]; then echo "ok   pure-go [$2]: runs, LC_VERSION_MIN_MACOSX 10.9: $(printf '%s' "$out" | tail -1)"
    else bad "pure-go [$2]: runs but minos is '${m:-none}', want 10.9 (internal-linked?)"; fi
  else bad "pure-go [$2]: does not run: $out"; fi
}
( cd "$tmp/pure" && go build -o "$tmp/pure-default" . ) && pure_check "$tmp/pure-default" default || bad "pure-go [default]: build failed"
( cd "$tmp/pure" && CGO_ENABLED=0 go build -o "$tmp/pure-nocgo" . ) && pure_check "$tmp/pure-nocgo" CGO_ENABLED=0 || bad "pure-go [CGO_ENABLED=0]: build failed"
if ( cd "$tmp/pure" && go test -c -o "$tmp/pure.test" . ); then pure_check "$tmp/pure.test" "go test binary"; else bad "pure-go [go test binary]: build failed"; fi
if ( cd "$tmp/pure" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$tmp/pure-linux" . ); then
  # spec: on-target suite, check 3 -- an ELF header: 0x7f E L F (the cross-OS build still links internally)
  if [ "$(head -c 4 "$tmp/pure-linux" | od -An -c | tr -d ' ')" = '177ELF' ]; then echo "ok   pure-go [GOOS=linux]: internal-linked ELF"
  else bad "pure-go [GOOS=linux]: not an ELF binary"; fi
else bad "pure-go [GOOS=linux]: build failed"; fi

# spec: on-target suite, check 4 -- cgo-own-polyfill: a cgo program that defines its own SecTrustEvaluateWithError must link, with the symbol defined once (its own)
cp -R "$here/cgo-own-polyfill" "$tmp/polyfill"
printf 'module cgoownpolyfill\n\n%s\n' "$gomod" > "$tmp/polyfill/go.mod"
if ( cd "$tmp/polyfill" && CGO_ENABLED=1 go build -o "$tmp/polyfill.bin" . ); then
  n="$("$clang22/bin/llvm-nm" -m "$tmp/polyfill.bin" | grep -cE '\(__TEXT,__text\) (non-)?external _SecTrustEvaluateWithError$' || true)"
  if [ "$n" = 1 ]; then
    if out="$("$tmp/polyfill.bin" 2>&1)"; then echo "ok   cgo-own-polyfill: _SecTrustEvaluateWithError defined once; runs: $out"
    else bad "cgo-own-polyfill: does not run: $out"; fi
  else bad "cgo-own-polyfill: _SecTrustEvaluateWithError is defined $n times, want once (the program's own)"; fi
else bad "cgo-own-polyfill: a cgo program that defines its own SecTrustEvaluateWithError must link"; fi

# spec: on-target suite, check 5 -- a plain cgo program builds and runs with no CGO_*/CC in the environment: go.env bakes them in
cp -R "$here/hello-cgo" "$tmp/hello"
printf 'module hellocgo\n\n%s\n' "$gomod" > "$tmp/hello/go.mod"
if out="$( cd "$tmp/hello" && go build -o "$tmp/hello.bin" . && "$tmp/hello.bin" 2>&1 )"; then echo "ok   hello-cgo: $out"
else bad "hello-cgo: $out"; fi

# spec: on-target suite, check 6 -- native-verifier-untrusted: a chain to an unknown CA is rejected by the union and by Apple's verifier alike
cp -R "$here/trust/untrusted" "$tmp/untrusted"
printf 'module untrusted\n\n%s\n' "$gomod" > "$tmp/untrusted/go.mod"
if ( cd "$tmp/untrusted" && go build -o "$tmp/untrusted.bin" . ); then
  want='REJECTED x509.UnknownAuthorityError'
  for mode in default native; do
    if [ "$mode" = native ]; then out="$(GODEBUG=x509usefallbackroots=0 "$tmp/untrusted.bin" 2>&1)" || true
    else out="$("$tmp/untrusted.bin" 2>&1)" || true; fi
    if [ "$out" = "$want" ]; then echo "ok   untrusted [$mode]: $out"
    else bad "untrusted [$mode]: want '$want', got: $out"; fi
  done
else bad "untrusted: the fixture does not build"; fi

[ "$fail" = 0 ] || exit 1
echo "PASS: on-target"
