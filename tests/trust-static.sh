#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- the trust checks that need no Mac, for the lines' build job: the patched tree still carries the 10.9 and
#       keychain-union fixes (source greps), crypto/x509 builds for each non-darwin GOOS (the overlay's !darwin stub), and on a
#       non-darwin host the build-tag-free keychain-union and fallback tests pass. What needs darwin is in tests/on-target/run.sh.
#       With neither variable set there is nothing to check: exit 77. One set but naming no built go is a failure (exit 1).
#       usage: sh tests/trust-static.sh            LINE_ROOT=<line checkout> finds the builder's $WORK/go (what make.bash built, patched)
#              TRUST_STATIC_GOROOT=<goroot> sh tests/trust-static.sh      any built, patched Go tree
set -u
here="$(cd "$(dirname "$0")" && pwd)"
goroot="${TRUST_STATIC_GOROOT:-}"
if [ -z "$goroot" ] && [ -n "${LINE_ROOT:-}" ]; then
  PORT_DIR="$(cd "$here/.." && pwd)"; export PORT_DIR
  goroot="$(. "$PORT_DIR/build/env.sh" >/dev/null && printf '%s' "$WORK/go")" || { echo "env.sh failed for $LINE_ROOT" >&2; exit 1; }
fi
[ -n "${TRUST_STATIC_GOROOT:-}" ] || [ -n "${LINE_ROOT:-}" ] || { echo "no toolchain named (set TRUST_STATIC_GOROOT, or LINE_ROOT after build-builder.sh) -- skipping"; exit 77; }
[ -x "$goroot/bin/go" ] || { echo "FAIL: no built go at $goroot/bin/go (run build-builder.sh for LINE_ROOT, or point TRUST_STATIC_GOROOT at a built tree)"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/trust-static.XXXXXX")" || exit 1
[ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
unset CC CXX CGO_ENABLED GOFLAGS GO_EXTLINK_ENABLED GOOS GOARCH GODEBUG SSL_CERT_FILE SSL_CERT_DIR
export GOROOT="$goroot" GOCACHE="$tmp/gocache" GOENV=off GOTOOLCHAIN=local GOPROXY=off
go="$goroot/bin/go"
x509="$goroot/src/crypto/x509"
fail=0
bad() { echo "FAIL: $*"; fail=1; }

# spec: PORT.md, the build chain -- OS X 10.9's SecTrustEvaluate faults when the policies argument is a CFArray, so systemVerify hands the SSL
#       policy to SecTrustCreateWithCertificates directly. A Linux job cannot run that path, so the source must say it.
grep -q 'SecTrustCreateWithCertificates(certs, sslPolicy)' "$x509/root_darwin.go" \
  || bad "root_darwin.go no longer passes the SSL policy directly to SecTrustCreateWithCertificates -- 10.9's SecTrustEvaluate faults on a policies CFArray"
# spec: PORT.md, the build chain -- loadSystemRoots hands darwin to the keychain union (the line's patch 0016)
grep -q 'keychainUnionPlatformRoots(); handled' "$x509/root.go" \
  || bad "root.go's loadSystemRoots no longer hands darwin to the keychain union (patch 0016)"

# spec: PORT.md, the build chain -- every non-darwin GOOS builds crypto/x509 through the overlay's root_keychainunion_other.go stub
for os in linux windows; do
  GOOS=$os GOARCH=amd64 CGO_ENABLED=0 "$go" build crypto/x509 \
    || bad "crypto/x509 does not build for GOOS=$os -- the !darwin keychainUnionPlatformRoots stub (the overlay's root_keychainunion_other.go) is missing"
done

# spec: PORT.md, the build chain -- the keychain union's pool building, veto and bundle resolution are build-tag-free, so a non-darwin host runs
#       their tests and upstream's fallback tests. On a darwin host tests/on-target/run.sh is the gate (the host's keychain decides skips).
if [ "$("$go" env GOHOSTOS)" != darwin ]; then
  out="$(CGO_ENABLED=0 "$go" test crypto/x509 -run 'KeychainUnion|Fallback' -count=1 -v 2>&1)" \
    || { printf '%s\n' "$out" | tail -40; bad "go test crypto/x509 -run 'KeychainUnion|Fallback' failed on the host"; }
  # spec: PORT.md, the build chain -- upstream's TestSetFallbackRoots subtests skip off darwin by design; a keychain-union test never may
  skipped="$(printf '%s\n' "$out" | grep -E '^[[:space:]]*--- (SKIP: Test[A-Za-z_]*KeychainUnion|FAIL: )' || true)"
  [ -z "$skipped" ] || bad "keychain-union tests skipped, or a test failed, on the host: $skipped"
  passed="$(printf '%s\n' "$out" | grep -c '^--- PASS: Test[A-Za-z_]*KeychainUnion' || true)"
  [ "$passed" -ge 11 ] || bad "expected >=11 build-tag-free KeychainUnion tests to pass on the host, saw $passed -- did -run match nothing?"
  for t in TestFallback TestFallbackPanic; do
    printf '%s\n' "$out" | grep -q "^--- PASS: $t " || bad "upstream $t did not pass on the host"
  done
fi

[ "$fail" = 0 ] || exit 1
echo "PASS: trust-static"
