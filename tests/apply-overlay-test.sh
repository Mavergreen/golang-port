#!/bin/sh
# platform: host-agnostic
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/apply-overlay-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT
x=src/crypto/x509

fail() { echo "FAIL: $*"; exit 1; }

mkgo() { mkdir -p "$1/$x" && : > "$1/$x/root.go"; }

# spec: tests/apply-overlay-test.sh -- expect_exit <want> <name> <must-match> -- args; output left in $t/out
expect_exit() {
  want=$1; name=$2; match=$3; shift 3
  rc=0
  sh "$here/apply-overlay.sh" "$@" >"$t/out" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || fail "$name: exit $rc, want $want: $(cat "$t/out")"
  grep -q -- "$match" "$t/out" || fail "$name: message lacks '$match': $(cat "$t/out")"
}

mkgo "$t/go"
expect_exit 0 "happy run" "overlay applied" "$t/go" /x/etc/openssl
for f in "$here"/overlay/$x/* "$here"/overlay/$x/testdata/*; do
  [ -f "$f" ] || continue
  b=${f#"$here"/overlay/$x/}
  [ -f "$t/go/$x/$b" ] || fail "overlay file $b was not copied"
  [ "$b" = root_keychainunion_darwin.go ] && continue
  cmp -s "$f" "$t/go/$x/$b" || fail "$b differs from overlay/"
done
grep -q '/x/etc/openssl/certs/ca-certificates.crt' "$t/go/$x/root_keychainunion_darwin.go" \
  || fail "ssldir was not baked into root_keychainunion_darwin.go"
(cd "$here/overlay" && find src -type f | sort) > "$t/want"
test "$(wc -l < "$t/want" | tr -d ' ')" = 6 || fail "overlay should hold exactly six files, has: $(cat "$t/want")"
(cd "$t/go" && find src -type f ! -path src/crypto/x509/root.go | sort) > "$t/got"
cmp -s "$t/want" "$t/got" || fail "copied files differ from overlay. want: $(cat "$t/want") got: $(cat "$t/got")"
if grep -r '@SSLDIR@' "$t/go/src" >/dev/null; then fail "@SSLDIR@ survives in the Go tree"; fi

mkgo "$t/g2"
expect_exit 2 "missing argument" "usage" "$t/g2"
expect_exit 2 "relative ssldir" "absolute" "$t/g2" etc/openssl
expect_exit 2 "ssldir with #" "#" "$t/g2" "/x/a#b"
expect_exit 2 "ssldir with &" "&" "$t/g2" "/x/a&b"
mkdir -p "$t/notgo"
expect_exit 2 "not a Go tree" "root.go" "$t/notgo" /x/etc/openssl

mkgo "$t/g3"
last=$x/testdata/keychainunion-isrgrootx1-chain.pem
mkdir -p "$t/g3/$x/testdata"
: > "$t/g3/$last"
expect_exit 1 "collision" "$t/g3/$last" "$t/g3" /x/etc/openssl
grep -q 'upstream now ships a file of that name' "$t/out" || fail "collision message lacks the upstream explanation"
while read -r o; do
  [ "$o" = "$last" ] && continue
  [ ! -e "$t/g3/$o" ] || fail "collision: $o was copied before the refusal"
done < "$t/want"

mkdir -p "$t/port"
cp "$here/apply-overlay.sh" "$t/port/"
cp -R "$here/overlay" "$t/port/overlay"
for f in "$t"/port/overlay/$x/*; do
  [ -f "$f" ] || continue
  grep -v '@SSLDIR@' "$f" > "$f.new"; mv "$f.new" "$f"
done
mkgo "$t/g4"
rc=0
sh "$t/port/apply-overlay.sh" "$t/g4" /x/etc/openssl >"$t/out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "no placeholder: exit $rc, want 1"
grep -q 'substituted nothing' "$t/out" || fail "no placeholder: message lacks 'substituted nothing'"

echo "PASS: apply-overlay.sh copies, substitutes, and refuses safely"
