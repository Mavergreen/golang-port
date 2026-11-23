#!/bin/sh
# platform: host-agnostic
here=$(cd "$(dirname "$0")/.." && pwd)
# spec: tests/fixtures/line-* are copies of what a line holds and stay out of the tarball, so this test skips there
ls -d "$here"/tests/fixtures/line-* >/dev/null 2>&1 || { echo "skip: no tests/fixtures/line-* (run from the tarball); this test needs the line fixtures"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/env-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# spec: build/env.sh -- sourced in a subshell, so its exit codes and exports can be read without leaking
# spec: build/env.sh -- env_of <line-root> -- prints NAME=value for every exported variable under test
env_of() {
  (
    PORT_DIR="$here"; LINE_ROOT="$1"; export PORT_DIR LINE_ROOT
    . "$here/build/env.sh" || exit $?
    for v in PORT_DIR LINE_ROOT GO_VERSION GO_LINE PREFIX CROSS_PREFIX CA_DIR MACOS_MIN \
             CROSS_MIN_OS RECAULK_VERSION CLANG22_VERSION CA_SHA256 CA_URL WLU_SYMS PKG_VERSION WORK; do
      eval "printf '%s=%s\n' $v \"\$$v\""
    done
  )
}

want() { grep -qx -- "$2" "$t/env" || fail "$1: want $2, got: $(grep "^${2%%=*}=" "$t/env")"; }

check_line() {
  line=$1; ver=$2; recaulk=$3; cross=$4
  fx="$here/tests/fixtures/line-$line"
  env_of "$fx" > "$t/env" 2>"$t/err" || fail "line $line: env.sh failed: $(cat "$t/err")"
  want "line $line" "PORT_DIR=$here"
  want "line $line" "LINE_ROOT=$fx"
  want "line $line" "GO_VERSION=$ver"
  want "line $line" "GO_LINE=$line"
  want "line $line" "PREFIX=/usr/local/mavergreen/go$line"
  want "line $line" "CROSS_PREFIX=/usr/local/mavergreen/go$line-cross"
  want "line $line" "CA_DIR=/usr/local/mavergreen/go$line/etc/openssl"
  want "line $line" "MACOS_MIN=10.9"
  want "line $line" "CROSS_MIN_OS=$cross"
  want "line $line" "RECAULK_VERSION=$recaulk"
  want "line $line" "CLANG22_VERSION=22.1.8-mavericks.25"
  want "line $line" "CA_SHA256=3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91"
  want "line $line" "CA_URL=https://curl.se/ca/cacert.pem"
  want "line $line" "WLU_SYMS=_xpc_date_create_from_current"
  want "line $line" "PKG_VERSION=$ver-mavericks.1"
  want "line $line" "WORK=$(printf '%s' "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/golang-go$line" | sed -e 's#//*#/#g')"
}

# spec: build/env.sh -- expect_fail <want-rc> <name> <must-match>... ; runs env_of on $root with $pre as extra env
expect_fail() {
  want=$1; name=$2; root=$3; shift 3
  rc=0
  env_of "$root" >"$t/out" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || fail "$name: exit $rc, want $want: $(cat "$t/out")"
  for m in "$@"; do
    grep -q -- "$m" "$t/out" || fail "$name: message lacks '$m': $(cat "$t/out")"
  done
}

check_line 126 1.26.11 20261122.2 11.0
check_line 127 1.27.4 20261122.2 13.0

# spec: build/env.sh -- no LINE_ROOT -> exit 2
rc=0
( unset LINE_ROOT; PORT_DIR="$here"; export PORT_DIR; . "$here/build/env.sh" ) >"$t/out" 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "no LINE_ROOT: exit $rc, want 2: $(cat "$t/out")"
grep -q LINE_ROOT "$t/out" || fail "no LINE_ROOT: message lacks LINE_ROOT: $(cat "$t/out")"

# spec: build/env.sh -- caller's GO_LINE disagreeing with UPSTREAM_VERSION -> exit 1 naming both
cp -R "$here/tests/fixtures/line-126" "$t/skew"
echo 1.27.4 > "$t/skew/UPSTREAM_VERSION"
rc=0
( GO_LINE=126; export GO_LINE; PORT_DIR="$here"; LINE_ROOT="$t/skew"; export PORT_DIR LINE_ROOT; . "$here/build/env.sh" ) >"$t/out" 2>&1 || rc=$?
[ "$rc" = 1 ] || fail "GO_LINE skew: exit $rc, want 1: $(cat "$t/out")"
grep -q 126 "$t/out" && grep -q 1.27.4 "$t/out" || fail "GO_LINE skew: message lacks 126 and 1.27.4: $(cat "$t/out")"


# spec: build/env.sh -- no PORT_DIR -> exit 2 naming PORT_DIR (a sourced file cannot find itself in every sh)
rc=0
( unset PORT_DIR; LINE_ROOT="$here/tests/fixtures/line-127"; export LINE_ROOT; . "$here/build/env.sh" ) >"$t/out" 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "no PORT_DIR: exit $rc, want 2: $(cat "$t/out")"
grep -q PORT_DIR "$t/out" || fail "no PORT_DIR: message lacks PORT_DIR: $(cat "$t/out")"

# spec: build/env.sh -- a stale VERSION (UPSTREAM 1.27.4, VERSION 1.27.3-mavericks.1) -> exit 1 naming both files and both values
cp -R "$here/tests/fixtures/line-127" "$t/stale"
echo 1.27.3-mavericks.1 > "$t/stale/VERSION"
expect_fail 1 "stale VERSION" "$t/stale" "UPSTREAM_VERSION" "VERSION" "1\.27\.4" "1\.27\.3-mavericks\.1"
# spec: build/env.sh -- a VERSION that is not <go>-mavericks.<digits> -> exit 1
for bad in 1.27.4 1.27.4-mavericks. 1.27.4-mavericks.x 1.27.4-mavericks.1.2 1.27.40-mavericks.1; do
  echo "$bad" > "$t/stale/VERSION"
  expect_fail 1 "VERSION $bad" "$t/stale" "$bad"
done
echo 1.27.4-mavericks.12 > "$t/stale/VERSION"
env_of "$t/stale" > "$t/env" 2>"$t/err" || fail "VERSION 1.27.4-mavericks.12 refused: $(cat "$t/err")"
want "multi-digit rev" "PKG_VERSION=1.27.4-mavericks.12"

# spec: build/env.sh -- no VERSION: the fallback is the line's build/version.sh auto; a stale or empty answer refuses too
cp -R "$here/tests/fixtures/line-127" "$t/auto"
rm "$t/auto/VERSION"; mkdir "$t/auto/build"
printf '#!/bin/sh\necho FULL=1.27.4-mavericks.7\n' > "$t/auto/build/version.sh"
env_of "$t/auto" > "$t/env" 2>"$t/err" || fail "fallback: env.sh failed: $(cat "$t/err")"
want "fallback" "PKG_VERSION=1.27.4-mavericks.7"
printf '#!/bin/sh\necho FULL=1.27.3-mavericks.7\n' > "$t/auto/build/version.sh"
expect_fail 1 "stale fallback" "$t/auto" "1\.27\.3-mavericks\.7" "UPSTREAM_VERSION"
printf '#!/bin/sh\necho nothing\n' > "$t/auto/build/version.sh"
expect_fail 1 "empty fallback" "$t/auto" "no package version" "version.sh"

# spec: build/env.sh -- missing line.env -> exit 1 naming the file
cp -R "$here/tests/fixtures/line-127" "$t/noenv"
rm "$t/noenv/line.env"
expect_fail 1 "missing line.env" "$t/noenv" "line.env"

# spec: build/env.sh -- the work paths are spelled clean (PORT.md, Fixed C-toolchain paths): an unclean GOROOT changes darwin/amd64 build IDs
work_of() { env_of "$here/tests/fixtures/line-127" | sed -n 's/^WORK=//p'; }
for case in "/a//b/|/a/b/golang-go127" "/a/./b/.|/a/b/golang-go127" "///a///|/a/golang-go127" "/|/golang-go127"; do
  got=$(MAVERICKS_BUILD_ROOT="${case%%|*}"; unset MAVERICKS_WORK; export MAVERICKS_BUILD_ROOT; work_of 2>"$t/err") || fail "root ${case%%|*}: $(cat "$t/err")"
  [ "$got" = "${case#*|}" ] || fail "MAVERICKS_BUILD_ROOT=${case%%|*}: WORK=$got, want ${case#*|}"
done
got=$(MAVERICKS_WORK="/w//x/./y/"; export MAVERICKS_WORK; work_of 2>"$t/err") || fail "MAVERICKS_WORK /w//x/./y/: $(cat "$t/err")"
[ "$got" = /w/x/y ] || fail "MAVERICKS_WORK=/w//x/./y/: WORK=$got, want /w/x/y"
got=$(MAVERICKS_BUILD_ROOT=/r; MAVERICKS_WORK=/a/b..c/.d; export MAVERICKS_BUILD_ROOT MAVERICKS_WORK; work_of 2>"$t/err") || fail "dotted names: $(cat "$t/err")"
[ "$got" = /a/b..c/.d ] || fail "MAVERICKS_WORK=/a/b..c/.d: WORK=$got, want it unchanged"
# spec: build/env.sh -- a relative work path, or one with a .. part, exits 2 naming the variable
for bad in "MAVERICKS_BUILD_ROOT=rel/root" "MAVERICKS_BUILD_ROOT=/a/../b" "MAVERICKS_WORK=w" "MAVERICKS_WORK=/a/b/.."; do
  rc=0
  ( unset MAVERICKS_WORK; export "${bad?}"; env_of "$here/tests/fixtures/line-127" ) >"$t/out" 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "$bad: exit $rc, want 2: $(cat "$t/out")"
  grep -q "${bad%%=*}" "$t/out" || fail "$bad: message lacks ${bad%%=*}: $(cat "$t/out")"
done

echo "ok: env-test"
