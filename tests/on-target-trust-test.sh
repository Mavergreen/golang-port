#!/bin/sh
# platform: host-agnostic
# spec: tests/on-target/run.sh -- check 2 holds every darwin assertion of the lines' old macOS-runner trust test: >=27 KeychainUnion passes,
#       TestFallback, TestFallbackPanic and TestSSLCertEnvOverride pass, patch 0018's four SKIPs carry their exact reasons, and no other
#       test skips. On Go 1.26, which builds only TestIssue51759 and TestHybridPool of the four on darwin and has no
#       TestSSLCertEnvOverride, those two SKIPs are required and the other three must not run. Proven here with a stub go replaying a go
#       test transcript, since the suite itself runs only in the 10.9 guest.
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/on-target-trust-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

die() { echo "FAIL: $*"; exit 1; }

# spec: tests/on-target-trust-test.sh -- the stub go: `go version` answers as go1.$STUB_MINOR (default 27) does on 10.9; `go test` prints $t/transcript; anything
#       else succeeds silently. `go test` exits $STUB_RC (default 0).
mkdir -p "$t/goroot/bin" "$t/clang22/bin"
cat > "$t/goroot/bin/go" <<EOF
#!/bin/sh
if [ "\$1" = version ]; then echo "go version go1.\${STUB_MINOR:-27}.1 darwin/amd64"; exit 0; fi
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

# spec: tests/on-target-trust-test.sh -- Go 1.26: good126 is the transcript go1.26 with golang-126's patches prints on 10.9 (its 0018
#       skips TestIssue51759 and TestHybridPool with 127's reasons; the other three tests do not exist on darwin)
good126() {
  [ -z "${EXTRA:-}" ] || printf '%s\n' "$EXTRA"
  i=1
  while [ $i -le 27 ]; do echo "--- PASS: TestKeychainUnionCase$i (0.00s)"; i=$((i + 1)); done
  echo "--- PASS: TestFallback (0.00s)"
  echo "--- PASS: TestFallbackPanic (0.00s)"
  echo "    verify_test.go:1704: darwin: Go's verifier over the keychain union is the default, not Apple's (PORT.md)"
  echo "--- SKIP: TestIssue51759 (0.00s)"
  echo "    hybrid_pool_test.go:24: darwin: Go's verifier over the keychain union is the default, and it does no AIA fetching (PORT.md)"
  echo "--- SKIP: TestHybridPool (0.00s)"
  echo "PASS"
  printf 'ok  \tcrypto/x509\t3.205s\n'
}
check2_126() {
  good126 | sed -e "$1" > "$t/transcript"
  STUB_MINOR=26 MAVERGREEN_CLANG22="$t/clang22" GOROOT="$t/goroot" sh "$here/tests/on-target/run.sh" > "$t/suite" 2>&1
  sed -n '/pure-go \[/q;/^FAIL: /p' "$t/suite" > "$t/fails"
}
expect126() { # name sed want-substring
  check2_126 "$2"
  grep -qF -- "$3" "$t/fails" || die "1.26 $1: check 2 should fail with '$3', got: $(cat "$t/fails")"
}
check2_126 ''
[ ! -s "$t/fails" ] || die "the good 1.26 transcript (no TestSSLCertEnvOverride, two SKIPs) should pass check 2: $(cat "$t/fails")"
grep -qF "ok   crypto/x509: 27 KeychainUnion tests, TestFallback, TestFallbackPanic; patch 0018's 2 SKIPs with their reasons" "$t/suite" \
  || die "the good 1.26 transcript should report ok with 2 SKIPs: $(cat "$t/suite")"
expect126 "TestHybridPool runs" 's/SKIP: TestHybridPool /PASS: TestHybridPool /' "upstream TestHybridPool did not SKIP on darwin"
expect126 "TestIssue51759 upstream reason" 's/verify_test.go:1704: darwin: .*/verify_test.go:1715: behavior only enforced in macOS 11 and after/' \
  "TestIssue51759 skipped, but its reason is not patch 0018's"
expect126 "26 KeychainUnion passes" '/TestKeychainUnionCase27 /d' "expected >=27 KeychainUnion tests to pass, saw 26"
EXTRA='--- PASS: TestEnvVars (0.00s)'
expect126 "TestEnvVars ran" '' "upstream TestEnvVars ran on darwin, but Go 1.26 does not build it there"
EXTRA='--- PASS: TestSSLCertEnvOverride (0.00s)'
expect126 "TestSSLCertEnvOverride ran" '' "upstream TestSSLCertEnvOverride ran on darwin, but Go 1.26 does not build it there"
EXTRA='    root_test.go:129: darwin: the keychain union serves the system roots (PORT.md)
--- SKIP: TestEnvVars (0.00s)'
expect126 "a 1.27-only SKIP on 1.26" '' "tests skipped on the target"
EXTRA=

echo "PASS: on-target-trust"
