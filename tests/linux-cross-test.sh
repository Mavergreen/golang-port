#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- the go1NN-cross linux-x86_64 archive (build/build-linux-cross.sh). A maintainer-supplied archive is
#       checked; the tests need one, so without it this skips (77), as every test that needs a built product does.
#       usage: LINUX_CROSS_TARBALL=<archive> [LINUX_CROSS_TARBALL_B=<second build of the same inputs>] sh tests/linux-cross-test.sh
#       Where a Linux x86_64 host has clang22 at $MAVERGREEN_CLANG22 (default /usr/local/mavergreen/clang22) and sdk109, it also
#       extracts the archive and builds tests/fixtures/hello with it; elsewhere that part skips and says so.
here=$(cd "$(dirname "$0")/.." && pwd)
tb="${LINUX_CROSS_TARBALL:-}"
[ -n "$tb" ] && [ -f "$tb" ] || { echo "set LINUX_CROSS_TARBALL to a built go1NN-cross-*-linux-x86_64.tar.gz -- skipping"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/linux-cross-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT
t=$(cd "$t" && pwd)
fail() { echo "FAIL: $*"; exit 1; }

base=${tb##*/}
line=$(printf '%s' "$base" | sed -n 's/^go\([0-9][0-9]*\)-cross-.*-linux-x86_64\.tar\.gz$/\1/p')
[ -n "$line" ] || fail "$base is not named go<line>-cross-<version>-linux-x86_64.tar.gz"
root="go$line-cross"

# spec: build/build-linux-cross.sh -- one top directory, and nothing for the host's own toolchain in pkg/tool
tar -tzf "$tb" > "$t/list" || fail "cannot list $tb"
tops=$(sed 's|/.*||' "$t/list" | sort -u)
[ "$tops" = "$root" ] || fail "top directories are '$tops', want only $root"
grep -q "^$root/pkg/tool/darwin_" "$t/list" && fail "pkg/tool/darwin_* is in the archive"
grep -q "^$root/pkg/tool/linux_amd64/link$" "$t/list" || fail "no pkg/tool/linux_amd64/link in the archive"
for f in bin/go bin/gofmt bin/mavericks-cross-clang lib/librecaulk.a go.env build-info-linux-cross.txt; do
  grep -q "^$root/$f$" "$t/list" || fail "no $f in the archive"
done
echo "ok: layout"

# spec: build/build-linux-cross.sh -- the archive's bin/go is a Linux x86-64 program (ELF, e_machine 0x3e), whatever host built it
tar -xzf "$tb" -C "$t" "$root/bin/go" || fail "cannot extract bin/go"
hd=$(od -An -tx1 -N20 "$t/$root/bin/go" | tr -d ' \n')
case "$hd" in 7f454c46*) ;; *) fail "bin/go is not an ELF file ($hd)" ;; esac
[ "$(printf '%s' "$hd" | cut -c37-40)" = 3e00 ] || fail "bin/go is not x86-64 (ELF header $hd)"
echo "ok: bin/go is an ELF x86-64"

# spec: build/build-linux-cross.sh -- gzip -n, sorted, owner 0:0, one mtime: two builds of the same inputs are the same bytes
if [ -n "${LINUX_CROSS_TARBALL_B:-}" ]; then
  [ -f "$LINUX_CROSS_TARBALL_B" ] || fail "no $LINUX_CROSS_TARBALL_B"
  cmp "$tb" "$LINUX_CROSS_TARBALL_B" || fail "two builds from the same inputs differ"
  echo "ok: two builds are byte-identical"
else
  echo "skip: LINUX_CROSS_TARBALL_B not set, no reproducibility check"
fi

cl="${MAVERGREEN_CLANG22:-/usr/local/mavergreen/clang22}"
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ] || [ ! -x "$cl/bin/clang" ] || [ ! -d /usr/local/mavergreen/sdk109/SDKs ]; then
  echo "skip: extract-and-build needs a Linux x86_64 host with clang22 ($cl) and sdk109"
  echo "PASS: linux-cross (layout only)"
  exit 0
fi

mkdir "$t/x" && tar -xzf "$tb" -C "$t/x" || fail "cannot extract $tb"
x="$t/x/$root"
# spec: build/build-linux-cross.sh -- go.env bakes the install@v1 prefix as CC; an archive extracted elsewhere sets CC itself
want_cc="/usr/local/mavergreen/$root/bin/mavericks-cross-clang"
grep -q "^CC=$want_cc\$" "$x/go.env" || fail "go.env has no CC=$want_cc: $(tail -4 "$x/go.env" | tr '\n' ' ')"

gorun() { env -i PATH="$x/bin:/usr/bin:/bin" HOME="$t" GOCACHE="${GC:-$t/cache}" GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=mod \
  CC="$x/bin/mavericks-cross-clang" MAVERGREEN_CLANG22="${MC:-$cl}" "$@"; }

[ "$(gorun "$x/bin/go" env GOOS)" = darwin ] || fail "GOOS does not default to darwin"
[ "$(gorun "$x/bin/go" env GOARCH)" = amd64 ] || fail "GOARCH does not default to amd64"
[ "$(gorun "$x/bin/go" env CGO_ENABLED)" = 1 ] || fail "CGO_ENABLED does not default to 1"
[ "$(env -i PATH=/usr/bin:/bin GOENV="$x/go.env" "$x/bin/go" env CC 2>/dev/null)" = "$want_cc" ] || \
  fail "go env CC is not $want_cc"
echo "ok: go.env defaults"

cp -R "$here/tests/fixtures/hello" "$t/hello"
( cd "$t/hello" && gorun "$x/bin/go" build -ldflags=-v -o "$t/hello.bin" . ) > "$t/build.out" 2>&1 || fail "go build failed: $(cat "$t/build.out")"
grep -q 'host link:' "$t/build.out" || fail "darwin/amd64 did not link external (no 'host link:' in go build -ldflags=-v)"
a=$("$cl/bin/llvm-lipo" -info "$t/hello.bin" | sed -n 's/^Non-fat file: .* is architecture: \([^ ]*\).*$/\1/p')
[ "$a" = x86_64 ] || fail "hello is '$a', want x86_64"
mv=$("$cl/bin/llvm-otool" -l "$t/hello.bin" | awk '
  $1 == "cmd" { c = $2; next }
  c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { m = $2 }
  c == "LC_BUILD_VERSION" && $1 == "minos" { m = $2 }
  END { print m }')
[ "$mv" = 10.9 ] || fail "hello has minos '$mv', want 10.9"
"$cl/bin/llvm-nm" "$t/hello.bin" | grep -q ' [Tt] _clock_gettime$' || fail "hello does not define _clock_gettime (Recaulk's polyfill)"
echo "ok: hello is Mach-O x86_64, minos 10.9, external link, _clock_gettime defined"

# spec: build/write-wrappers.sh -- Review Focus 4: no clang22 where the wrapper looks, and `go build` fails naming clang22 (it
#       does not fall back to the default path)
rm -rf "$t/cache2"
rc=0
( cd "$t/hello" && MC=/nonexistent GC="$t/cache2" gorun "$x/bin/go" build -o "$t/hello2.bin" . ) > "$t/nobuild.out" 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "go build succeeded with MAVERGREEN_CLANG22=/nonexistent (it fell back to another clang22)"
grep -q 'clang22 is not installed' "$t/nobuild.out" || fail "the failure does not name clang22: $(cat "$t/nobuild.out")"
grep -q '/nonexistent/bin/clang' "$t/nobuild.out" || fail "the failure does not name /nonexistent/bin/clang: $(cat "$t/nobuild.out")"
echo "ok: absent clang22 fails naming it"
echo "PASS: linux-cross"
