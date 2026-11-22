#!/bin/sh
# platform: host-agnostic
# spec: build/fetch-go.sh, build/fetch-ca.sh -- Offline tests for build/fetch-go.sh (tarball pre-placed, GO_DL_JSON feed) and build/fetch-ca.sh (vendored path).
here=$(cd "$(dirname "$0")/.." && pwd)
# spec: tests/fixtures/line-* are copies of what a line holds and stay out of the tarball, so this test skips there
ls -d "$here"/tests/fixtures/line-* >/dev/null 2>&1 || { echo "skip: no tests/fixtures/line-* (run from the tarball); this test needs the line fixtures"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/fetch-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# spec: build/fetch-*.sh -- scripts source shipyard's mavericks_fetch.sh; a stub whose shipyard_curl fails stands in, so any network use is a failure
mkdir "$t/ship"
printf 'shipyard_curl() { echo "shipyard_curl called: $*" >&2; return 1; }\n' > "$t/ship/mavericks_fetch.sh"
SHIPYARD_SCRIPTS="$t/ship"; export SHIPYARD_SCRIPTS

mkline() {
  rm -rf "$t/line"; cp -R "$here/tests/fixtures/line-127" "$t/line"
  mkdir "$t/line/vendor"; printf 'ISRG Root X1\n' > "$t/line/vendor/cacert.pem"
  sum=$(shasum -a 256 "$t/line/vendor/cacert.pem" | awk '{print $1}')
  printf 'CROSS_MIN_OS=13.0\nCA_SHA256=%s\n' "${1:-$sum}" > "$t/line/line.env"
}

# spec: build/fetch-ca.sh -- vendored path, mismatch, refresh
mkline
out=$(LINE_ROOT="$t/line" MAVERICKS_WORK="$t/w" sh "$here/build/fetch-ca.sh" 2>"$t/err") || fail "fetch-ca: $(cat "$t/err")"
[ "$out" = "$t/w/ca-certificates.crt" ] || fail "fetch-ca printed '$out'"
cmp -s "$out" "$t/line/vendor/cacert.pem" || fail "fetch-ca: bundle differs from the vendored one"
mkline 0000000000000000000000000000000000000000000000000000000000000000
if LINE_ROOT="$t/line" MAVERICKS_WORK="$t/w2" sh "$here/build/fetch-ca.sh" >/dev/null 2>"$t/err"; then fail "fetch-ca accepted a wrong CA_SHA256"; fi
grep -q 'vendored CA sha256 mismatch' "$t/err" || fail "fetch-ca mismatch not reported: $(cat "$t/err")"
mkline 0000000000000000000000000000000000000000000000000000000000000000
if MAVERICKS_CA_REFRESH=1 LINE_ROOT="$t/line" MAVERICKS_WORK="$t/w3" sh "$here/build/fetch-ca.sh" >/dev/null 2>"$t/err"; then fail "refresh succeeded with a failing download"; fi
grep -q 'shipyard_curl called' "$t/err" || fail "refresh did not fetch"

# spec: build/fetch-go.sh -- pre-placed tarball, matched against the feed
mkdir -p "$t/src/go/src"; : > "$t/src/go/src/make.bash"
ver=$(tr -d '[:space:]' < "$here/tests/fixtures/line-127/UPSTREAM_VERSION")
mkdir -p "$t/w4"; tar -C "$t/src" -czf "$t/w4/go$ver.src.tar.gz" go
sum=$(shasum -a 256 "$t/w4/go$ver.src.tar.gz" | awk '{print $1}')
printf '[{"version":"go%s","files":[{"filename":"go%s.src.tar.gz","kind":"source","sha256":"%s"}]}]\n' "$ver" "$ver" "$sum" > "$t/feed.json"
mkline
out=$(GO_DL_JSON="$t/feed.json" LINE_ROOT="$t/line" MAVERICKS_WORK="$t/w4" sh "$here/build/fetch-go.sh" 2>&1) || fail "fetch-go: $out"
[ -f "$t/w4/go/src/make.bash" ] || fail "fetch-go left no tree"
printf '[{"version":"go%s","files":[{"filename":"go%s.src.tar.gz","kind":"source","sha256":"deadbeef"}]}]\n' "$ver" "$ver" > "$t/feed.json"
if GO_DL_JSON="$t/feed.json" LINE_ROOT="$t/line" MAVERICKS_WORK="$t/w4" sh "$here/build/fetch-go.sh" >"$t/out" 2>&1; then fail "fetch-go accepted a hash mismatch"; fi
grep -q 'SHA256 mismatch' "$t/out" || fail "mismatch not reported: $(cat "$t/out")"

echo "PASS: fetch"
