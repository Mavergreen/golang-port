#!/bin/sh
# platform: host-agnostic
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/tarball-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# spec: build/tarball.sh -- it archives a fixed path list, so untracked files in the clone cannot leak in
git clone -q "$here" "$t/clone" || fail "clone"
mkdir -p "$t/clone/build"
cp "$here/UPSTREAM_VERSION" "$t/clone/UPSTREAM_VERSION"
[ -f "$here/build/tarball.sh" ] && cp "$here/build/tarball.sh" "$t/clone/build/tarball.sh"
v=$(tr -d '[:space:]' < "$t/clone/UPSTREAM_VERSION")

rc=0
sh "$t/clone/build/tarball.sh" "$t/out" >"$t/log" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "tarball.sh exit $rc: $(cat "$t/log")"
tb="$t/out/golang-port-$v.tar.gz"
[ -f "$tb" ] || fail "no $tb"

tar -tzf "$tb" | sed 's|/$||' | sort > "$t/got"
bad=$(grep -v "^golang-port-$v\(/\|$\)" "$t/got" || true)
[ -z "$bad" ] || fail "entries outside golang-port-$v/: $bad"
mkdir "$t/x" && tar -xzf "$tb" -C "$t/x" || fail "extract"
[ "$(ls "$t/x")" = "golang-port-$v" ] || fail "want one top directory golang-port-$v, got: $(ls "$t/x")"
x="$t/x/golang-port-$v"
(cd "$x" && find . -type f | sed 's|^\./||' | sort) > "$t/files"
# spec: build/tarball.sh -- the port's own files: the overlay, and now the build chain (build/, CMakeLists.txt, updater/, resources/, tests/);
#       the line fixtures stay out, because a fixture is a copy of what a line holds, not something a line extracts from here
(cd "$t/clone" && git ls-tree -r --name-only HEAD | grep -E '^(LICENSE$|PORT\.md$|apply-overlay\.sh$|CMakeLists\.txt$|(overlay|build|updater|resources|tests)/)' | grep -v '^tests/fixtures/line-' | sort) > "$t/want"
for must in build/tarball.sh build/env.sh CMakeLists.txt tests/tarball-test.sh tests/fixtures/hello/main.go updater resources; do
  grep -q "^$must" "$t/want" || fail "the clone's HEAD lacks $must, so this test cannot check it is archived"
  grep -q "^$must" "$t/files" || fail "$must is missing from the tarball"
done
if grep -q '^tests/fixtures/line-' "$t/files"; then fail "tests/fixtures/line-* is in the tarball"; fi
cmp -s "$t/want" "$t/files" || fail "file list differs. want: $(cat "$t/want") got: $(cat "$t/files")"

mkdir -p "$t/go/src/crypto/x509" && : > "$t/go/src/crypto/x509/root.go"
rc=0
sh "$x/apply-overlay.sh" "$t/go" /x/etc/openssl >"$t/log" 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "extracted apply-overlay.sh exit $rc: $(cat "$t/log")"

# spec: build/tarball.sh -- reproducible: the same commit gives the same bytes (gzip -n, git archive's fixed mtimes)
sh "$t/clone/build/tarball.sh" "$t/again" >/dev/null 2>&1 || fail "second tarball.sh run"
cmp -s "$tb" "$t/again/golang-port-$v.tar.gz" || fail "two runs on one commit gave different bytes"

printf '1.0\n' > "$t/clone/UPSTREAM_VERSION"
rc=0
sh "$t/clone/build/tarball.sh" "$t/out2" >"$t/log" 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "non-semver UPSTREAM_VERSION: exit $rc, want 2: $(cat "$t/log")"

echo "PASS: tarball-test"
