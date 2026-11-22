#!/bin/sh
# platform: host-agnostic
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/apply-patches-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# spec: build/apply-patches.sh -- env.sh needs shipyard's scripts located; a throwaway dir stands in (the script never runs them)
[ -n "${SHIPYARD_SCRIPTS:-}" ] && [ -d "$SHIPYARD_SCRIPTS" ] || { mkdir "$t/ship"; SHIPYARD_SCRIPTS="$t/ship"; }
export SHIPYARD_SCRIPTS

# spec: tests/apply-patches-test.sh -- mkgo <dir>: a fake Go tree with the file the fixture hook edits
mkgo() {
  mkdir -p "$1/src/crypto/x509"
  : > "$1/src/make.bash"
  printf 'package x509\n\nfunc loadSystemRoots() {}\n' > "$1/src/crypto/x509/root.go"
}

# spec: build/apply-patches.sh -- run <line> <work>: runs the script on a copy of the fixture line; output in $t/out
run() {
  rm -rf "$t/line"; cp -R "$here/tests/fixtures/$1" "$t/line"
  LINE_ROOT="$t/line" MAVERICKS_WORK="$2" sh "$here/build/apply-patches.sh" >"$t/out" 2>&1
}

x=src/crypto/x509
for line in line-126 line-127; do
  w="$t/w-$line"; mkgo "$w/go"
  run $line "$w" || fail "$line: apply-patches exited nonzero: $(cat "$t/out")"
  grep -q '// hook applied' "$w/go/$x/root.go" || fail "$line: hook patch not applied"
  for f in root_keychainunion.go root_keychainunion_darwin.go root_keychainunion_darwin_test.go root_keychainunion_other.go root_keychainunion_test.go testdata/keychainunion-isrgrootx1-chain.pem; do
    [ -f "$w/go/$x/$f" ] || fail "$line: overlay file $f missing"
  done
  if grep -r '@SSLDIR@' "$w/go/src" >/dev/null; then fail "$line: @SSLDIR@ survives"; fi
  grep -q "/usr/local/mavergreen/go${line#line-}/etc/openssl/certs/ca-certificates.crt" "$w/go/$x/root_keychainunion_darwin.go" \
    || fail "$line: CA path not baked into root_keychainunion_darwin.go"
  n=$(find "$w/go" \( -name '*.orig' -o -name '*.rej' -o -name '*~' \) | wc -l | tr -d ' ')
  [ "$n" = 0 ] || fail "$line: $n .orig/.rej files left behind"
done

# spec: build/apply-patches.sh -- a hook patch that does not apply exits nonzero and names itself
w="$t/w-bad"; mkgo "$w/go"; printf 'completely\ndifferent\nfile\n' > "$w/go/$x/root.go"
rc=0; run line-127 "$w" || rc=$?
[ "$rc" != 0 ] || fail "a patch that does not apply exited 0"
grep -q '0016-root-hook.patch does not apply' "$t/out" || fail "failure does not name the patch: $(cat "$t/out")"
if grep -q 'overlay applied' "$t/out"; then fail "overlay ran after a failed hook patch"; fi
n=$(find "$w/go" -name '*.orig' | wc -l | tr -d ' ')
[ "$n" = 0 ] || fail "failed apply left $n .orig files"

# spec: build/apply-patches.sh -- no Go tree, no patches
rc=0; run line-127 "$t/nowork" || rc=$?
[ "$rc" != 0 ] && grep -q 'fetch-go.sh first' "$t/out" || fail "missing Go tree not reported"
w="$t/w-nop"; mkgo "$w/go"
rm -rf "$t/line"; cp -R "$here/tests/fixtures/line-127" "$t/line"; rm -rf "$t/line/patches"
rc=0; LINE_ROOT="$t/line" MAVERICKS_WORK="$w" sh "$here/build/apply-patches.sh" >"$t/out" 2>&1 || rc=$?
[ "$rc" != 0 ] && grep -q 'no patches' "$t/out" || fail "missing patches not reported"

echo "PASS: apply-patches"
