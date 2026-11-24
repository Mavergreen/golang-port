#!/bin/sh
# platform: host-agnostic
# spec: tests/trust-static.sh -- the loadSystemRoots hook is checked where the line's Go minor keeps it, and only there: root.go's
#       `keychainUnionPlatformRoots(); handled` (patch 0016) from Go 1.27, root_darwin.go's `return keychainUnionLoadSystemRoots()` (patch 0013)
#       on Go 1.26. Proven with tests/fixtures/line-126 and line-127 and a stub go over a tree holding one hook or the other; a tree of another
#       minor than its line fails.
here=$(cd "$(dirname "$0")/.." && pwd)
# spec: tests/fixtures/line-* are copies of what a line holds and stay out of the tarball, so this test skips there
ls -d "$here"/tests/fixtures/line-* >/dev/null 2>&1 || { echo "skip: no tests/fixtures/line-* (run from the tarball); this test needs the line fixtures"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/trust-static-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$t/shipyard"
SHIPYARD_SCRIPTS="$t/shipyard"; export SHIPYARD_SCRIPTS

# spec: tests/trust-static-test.sh -- tree <dir> <go version> <hook: 126|127> -- a stub Go tree: VERSION, the 10.9 systemVerify fix, the hook,
#       and a go that builds anything, says its host is linux, and prints a passing keychain-union and fallback transcript
tree() {
  d=$1; mkdir -p "$d/bin" "$d/src/crypto/x509"
  printf '%s\ntime 2026-01-01T00:00:00Z\n' "$2" > "$d/VERSION"
  printf 'package x509\n' > "$d/src/crypto/x509/root.go"
  printf 'package x509\n\tSecTrustCreateWithCertificates(certs, sslPolicy)\n' > "$d/src/crypto/x509/root_darwin.go"
  case "$3" in
    127) printf '\tif pool, handled, err := keychainUnionPlatformRoots(); handled {\n' >> "$d/src/crypto/x509/root.go" ;;
    126) printf '\treturn keychainUnionLoadSystemRoots()\n' >> "$d/src/crypto/x509/root_darwin.go" ;;
  esac
  cat > "$d/bin/go" <<'GOEOF'
#!/bin/sh
case "$1" in
  env) echo linux ;;
  test) i=1; while [ $i -le 11 ]; do echo "--- PASS: TestKeychainUnionCase$i (0.00s)"; i=$((i + 1)); done
        echo "--- PASS: TestFallback (0.00s)"; echo "--- PASS: TestFallbackPanic (0.00s)"; echo PASS ;;
esac
exit 0
GOEOF
  chmod +x "$d/bin/go"
}
# spec: tests/trust-static-test.sh -- run_line <line> <go version> <hook> -- the builder tree at the WORK env.sh derives for that fixture
run_line() {
  rm -rf "$t/mbr"; tree "$t/mbr/golang-go$1/go" "$2" "$3"
  LINE_ROOT="$here/tests/fixtures/line-$1" MAVERICKS_BUILD_ROOT="$t/mbr" sh "$here/tests/trust-static.sh" > "$t/out" 2>&1
}
pass() { run_line "$@" || fail "line $1, tree $2 with the $3 hook should pass: $(cat "$t/out")"; grep -q '^PASS: trust-static' "$t/out" || fail "no PASS line: $(cat "$t/out")"; }
refuse() { # line version hook want
  if run_line "$1" "$2" "$3"; then fail "line $1, tree $2 with the $3 hook should fail: $(cat "$t/out")"; fi
  grep -qF -- "$4" "$t/out" || fail "line $1, tree $2 with the $3 hook: want '$4', got: $(cat "$t/out")"
}

pass 126 go1.26.11 126
pass 127 go1.27.4 127
refuse 126 go1.26.11 127 "root_darwin.go's loadSystemRoots no longer serves the keychain union (Go 1.26: the line's patch 0013)"
refuse 127 go1.27.4 126 "root.go's loadSystemRoots no longer hands darwin to the keychain union (Go 1.27: the line's patch 0016)"
refuse 126 go1.27.4 127 "is Go 1.26, but the tree at"

# spec: tests/trust-static-test.sh -- TRUST_STATIC_GOROOT names no line, so the tree's VERSION decides
tree "$t/g126" go1.26.11 126
TRUST_STATIC_GOROOT="$t/g126" sh "$here/tests/trust-static.sh" > "$t/out" 2>&1 || fail "a go1.26 tree with 0013's hook should pass: $(cat "$t/out")"
tree "$t/g126b" go1.26.11 127
TRUST_STATIC_GOROOT="$t/g126b" sh "$here/tests/trust-static.sh" > "$t/out" 2>&1 && fail "a go1.26 tree with only 0016's hook should fail: $(cat "$t/out")"
echo "PASS: trust-static-test"
