#!/bin/sh
# platform: host-agnostic
# spec: tests/on-target/run.sh -- check 2 holds every darwin assertion of the lines' old macOS-runner trust test: >=27 KeychainUnion passes,
#       TestFallback, TestFallbackPanic and TestSSLCertEnvOverride pass, patch 0018's four SKIPs carry their exact reasons, and no other
#       test skips. Proven here with a stub go replaying a go test transcript, since the suite itself runs only in the 10.9 guest.
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/on-target-trust-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

die() { echo "FAIL: $*"; exit 1; }

# spec: tests/on-target-trust-test.sh -- the stub go: `go version` answers as go1.27 does on 10.9; `go test` prints $t/transcript; anything
#       else succeeds silently. `go test` exits $STUB_RC (default 0).
mkdir -p "$t/goroot/bin" "$t/clang22/bin"
cat > "$t/goroot/bin/go" <<EOF
#!/bin/sh
if [ "\$1" = version ]; then echo "go version go1.27.1 darwin/amd64"; exit 0; fi
if [ "\$1" = test ]; then cat "$t/transcript"; exit "\${STUB_RC:-0}"; fi
exit 0
EOF
for x in llvm-nm llvm-otool; do printf '#!/bin/sh\n' > "$t/clang22/bin/$x"; chmod +x "$t/clang22/bin/$x"; done
chmod +x "$t/goroot/bin/go"

# spec: tests/on-target-trust-test.sh -- good: a transcript shaped as go1.27 with the lines' patches prints it on 10.9
good() {
  [ -z "${EXTRA:-}" ] || printf '%s\n' "$EXTRA"
  i=1
  while [ $i -le 27 ]; do echo "--- PASS: TestKeychainUnionCase$i (0.00s)"; i=$((i + 1)); done
  echo "--- PASS: TestFallback (0.00s)"
  echo "--- PASS: TestFallbackPanic (0.00s)"
  echo "--- PASS: TestSSLCertEnvOverride (0.06s)"
  echo "    root_test.go:129: darwin: the keychain union serves the system roots and SSL_CERT_* shapes its bundle files without replacing it (PORT.md)"
  echo "--- SKIP: TestEnvVars (0.00s)"
  echo "    root_test.go:259: darwin: the keychain union serves the system roots and SSL_CERT_* shapes its bundle files without replacing it (PORT.md)"
  echo "--- SKIP: TestLoadSystemCertsLoadColonSeparatedDirs (0.00s)"
  echo "    verify_test.go:1704: darwin: Go's verifier over the keychain union is the default, not Apple's (PORT.md)"
  echo "--- SKIP: TestIssue51759 (0.00s)"
  echo "    hybrid_pool_test.go:24: darwin: Go's verifier over the keychain union is the default, and it does no AIA fetching (PORT.md)"
  echo "--- SKIP: TestHybridPool (0.00s)"
  echo "PASS"
  printf 'ok  \tcrypto/x509\t3.205s\n'
}

# spec: tests/on-target-trust-test.sh -- check2 <sed script>: runs the suite on the good transcript edited by the sed script and leaves
#       check 2's FAIL lines (those before the first pure-go line) in $t/fails
check2() {
  good | sed -e "$1" > "$t/transcript"
  MAVERGREEN_CLANG22="$t/clang22" GOROOT="$t/goroot" sh "$here/tests/on-target/run.sh" > "$t/suite" 2>&1
  sed -n '/pure-go \[/q;/^FAIL: /p' "$t/suite" > "$t/fails"
}
expect() { # name sed want-substring
  check2 "$2"
  grep -qF -- "$3" "$t/fails" || die "$1: check 2 should fail with '$3', got: $(cat "$t/fails")"
}

check2 ''
[ ! -s "$t/fails" ] || die "the good transcript should pass check 2: $(cat "$t/fails")"
grep -qF "ok   crypto/x509: 27 KeychainUnion tests" "$t/suite" || die "the good transcript should report ok: $(cat "$t/suite")"

expect "26 KeychainUnion passes" '/TestKeychainUnionCase27 /d' "expected >=27 KeychainUnion tests to pass, saw 26"
expect "a KeychainUnion skip" 's/PASS: TestKeychainUnionCase3 /SKIP: TestKeychainUnionCase3 /' "tests skipped on the target"
EXTRA='    --- SKIP: TestFallback/sub (0.00s)'
expect "a subtest skip" '' "tests skipped on the target"
EXTRA=
expect "no TestFallback" '/^--- PASS: TestFallback (/d' "upstream TestFallback did not pass"
expect "no TestFallbackPanic" '/TestFallbackPanic/d' "upstream TestFallbackPanic did not pass"
expect "no TestSSLCertEnvOverride" '/TestSSLCertEnvOverride/d' "TestSSLCertEnvOverride did not pass"
expect "TestEnvVars passes" 's/SKIP: TestEnvVars /PASS: TestEnvVars /' "upstream TestEnvVars did not SKIP on darwin"
expect "TestHybridPool missing" '/TestHybridPool/d' "upstream TestHybridPool did not SKIP on darwin"
expect "wrong reason" 's/root_test.go:259: darwin: the keychain union serves/root_test.go:259: no network/' \
  "TestLoadSystemCertsLoadColonSeparatedDirs skipped, but its reason is not patch 0018's"
expect "reason without darwin:" 's/verify_test.go:1704: darwin: /verify_test.go:1704: /' "TestIssue51759 skipped, but its reason is not patch 0018's"
expect "no ok line" '/^ok /d' "go test crypto/x509 did not report ok"
STUB_RC=1; export STUB_RC
expect "go test exits 1" '' "go test crypto/x509 failed"
unset STUB_RC
EXTRA='    --- FAIL: TestFallback/sub (0.00s)'
expect "a FAIL line" '' "tests failed on the target"
EXTRA=
expect "reasons swapped" 's/root_test.go:129: darwin: .*/root_test.go:129: darwin: Go'"'"'s verifier over the keychain union is the default (PORT.md)/' \
  "TestEnvVars skipped, but its reason is not patch 0018's"
expect "a SKIP with no reason line" '/hybrid_pool_test.go:24:/d' "TestHybridPool skipped, but its reason is not patch 0018's"

echo "PASS: on-target-trust"
