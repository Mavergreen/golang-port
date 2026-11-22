#!/bin/sh
# platform: host-agnostic
# spec: tests/on-target/build-output.sh -- a linker warning in any on-target build's output fails that check, naming the line; proven
#       here with a stub go, since the suite itself runs only in the 10.9 guest
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/on-target-output-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

die() { echo "FAIL: $*"; exit 1; }
WARN='ld64.lld: warning: /tmp/go-link-1/go.o has version 13.0.0, which is newer than target minimum of 10.9.0'

# spec: tests/on-target/build-output.sh -- a stub go: `go version` answers as go1.27 does on 10.9; anything else prints $STUB_OUT on
#       stderr and exits $STUB_RC
mkdir -p "$t/goroot/bin" "$t/clang22/bin"
cat > "$t/goroot/bin/go" <<'EOF'
#!/bin/sh
if [ "$1" = version ]; then echo "go version go1.27.1 darwin/amd64"; exit 0; fi
[ -z "${STUB_OUT:-}" ] || printf '%s\n' "$STUB_OUT" >&2
exit "${STUB_RC:-0}"
EOF
for x in llvm-nm llvm-otool; do printf '#!/bin/sh\n' > "$t/clang22/bin/$x"; chmod +x "$t/clang22/bin/$x"; done
chmod +x "$t/goroot/bin/go"

# spec: tests/on-target/build-output.sh -- unit: ot_build and ot_check_output, with the caller's bad recording what it was told
stub() { STUB_OUT=$1; STUB_RC=${2:-0}; export STUB_OUT STUB_RC; }
GO_LINE=127
bad() { echo "$*" >> "$t/bad"; }
. "$here/tests/on-target/build-output.sh"
PATH="$t/goroot/bin:$PATH"
export PATH

: > "$t/bad"
stub "$WARN"
rc=0; ot_build "pure-go [default]" "$t" go build -o x . > "$t/printed" || rc=$?
[ "$rc" = 0 ] || die "ot_build should return the build's own status (0), got $rc"
grep -qF "go127 pure-go [default]: the build printed a linker warning" "$t/bad" || die "the newer-than-target warning did not fail the check, naming the line: $(cat "$t/bad")"
grep -qF "newer than target minimum" "$t/bad" || die "the failure does not quote the warning: $(cat "$t/bad")"
grep -qF "$WARN" "$t/printed" || die "ot_build should still print the build's output"

: > "$t/bad"
stub 'ld64.lld: warning: directory not found for option -L/nowhere'
ot_build "hello-cgo" "$t" go build . > /dev/null
grep -qF "go127 hello-cgo: the build printed a linker warning" "$t/bad" || die "any ld64.lld warning must fail the check"

: > "$t/bad"
stub 'cgo: x.o has version 13.0.0, which is newer than target minimum of 10.9.0'
ot_build "cgo-own-polyfill" "$t" go build . > /dev/null
grep -qF "go127 cgo-own-polyfill: the build printed a linker warning" "$t/bad" || die "'newer than target minimum' from any linker must fail the check"

: > "$t/bad"
stub '# purego'
rc=0; ot_build "clean" "$t" go build . > /dev/null || rc=$?
[ "$rc" = 0 ] && [ ! -s "$t/bad" ] || die "a clean build should pass: rc $rc, $(cat "$t/bad")"
stub 'main.go:1: syntax error' 1
rc=0; ot_build "broken" "$t" go build . > /dev/null || rc=$?
[ "$rc" = 1 ] && [ ! -s "$t/bad" ] || die "a failing build with no warning should return 1 and leave its failure to the caller: rc $rc, $(cat "$t/bad")"
ot_check_output "crypto/x509 tests" "ok crypto/x509
$WARN"
grep -qF "go127 crypto/x509 tests: the build printed a linker warning" "$t/bad" || die "ot_check_output did not catch the warning in captured go test output"

# spec: tests/on-target/run.sh -- suite: run.sh, with the stub go warning on every build, fails every build check by name and exits 1
rc=0
STUB_OUT="$WARN" MAVERGREEN_CLANG22="$t/clang22" GOROOT="$t/goroot" sh "$here/tests/on-target/run.sh" > "$t/suite" 2>&1 || rc=$?
[ "$rc" = 1 ] || die "run.sh with a warning on every link should exit 1, got $rc: $(cat "$t/suite")"
for label in "crypto/x509 tests" "pure-go [default]" "pure-go [CGO_ENABLED=0]" "pure-go [go test binary]" "pure-go [GOOS=linux]" \
             "cgo-own-polyfill" "hello-cgo" "untrusted"; do
  grep -qF "FAIL: go127 $label: the build printed a linker warning" "$t/suite" || die "run.sh does not check the output of '$label' for linker warnings: $(cat "$t/suite")"
done
stub ''
rc=0
MAVERGREEN_CLANG22="$t/clang22" GOROOT="$t/goroot" sh "$here/tests/on-target/run.sh" > "$t/suite" 2>&1 || rc=$?
! grep -q "linker warning" "$t/suite" || die "run.sh reported a linker warning that no build printed: $(cat "$t/suite")"

echo "PASS: on-target-output"
