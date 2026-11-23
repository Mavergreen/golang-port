#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- the go1NN-cross linux-x86_64 archive (build/build-linux-cross.sh). A maintainer-supplied archive is
#       checked; the tests need one, so without it this skips (77), as every test that needs a built product does.
#       usage: LINUX_CROSS_TARBALL=<archive> [LINUX_CROSS_TARBALL_B=<second build of the same inputs>] sh tests/linux-cross-test.sh
#       With python3 and shipyard's scripts (SHIPYARD_SCRIPTS), it installs the archive through product-tar.py, install@v1's own
#       unpacker. Where a Linux x86_64 host has clang22 at $MAVERGREEN_CLANG22 (default /usr/local/mavergreen/clang22) and sdk109, it
#       also builds tests/fixtures/hello with the installed tree; elsewhere that part skips and says so.
here=$(cd "$(dirname "$0")/.." && pwd)
tb="${LINUX_CROSS_TARBALL:-}"
[ -n "$tb" ] && [ -f "$tb" ] || { echo "set LINUX_CROSS_TARBALL to a built go1NN-cross-*-linux-x86_64.tar.gz -- skipping"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/linux-cross-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT
# spec: build/build-linux-cross.sh -- spelled physically: product-tar.py refuses a destination below a symlink (a Mac's /var is one)
t=$(cd "$t" && pwd -P)
fail() { echo "FAIL: $*"; exit 1; }

base=${tb##*/}
line=$(printf '%s' "$base" | sed -n 's/^go\([0-9][0-9]*\)-cross-.*-linux-x86_64\.tar\.gz$/\1/p')
[ -n "$line" ] || fail "$base is not named go<line>-cross-<version>-linux-x86_64.tar.gz"
version=$(printf '%s' "$base" | sed -n 's/^go[0-9][0-9]*-cross-\(.*\)-linux-x86_64\.tar\.gz$/\1/p')
root="go$line-cross"
p="opt/mavergreen/$root"

# spec: build/build-linux-cross.sh -- every entry is under opt/mavergreen/go1NN-cross (or is one of its two parent directories): the one
#       prefix shipyard's product-tar.py accepts. Nothing for the host's own toolchain in pkg/tool.
tar -tzf "$tb" > "$t/list" || fail "cannot list $tb"
stray=$(sed 's|/$||' "$t/list" | awk -v p="$p" '$0 != "opt" && $0 != "opt/mavergreen" && $0 != p && index($0, p "/") != 1')
[ -z "$stray" ] || fail "entries outside $p/: $(printf '%s' "$stray" | head -5 | tr '\n' ' ')"
grep -q "^$p/pkg/tool/darwin_" "$t/list" && fail "pkg/tool/darwin_* is in the archive"
grep -q "^$p/pkg/tool/linux_amd64/link$" "$t/list" || fail "no pkg/tool/linux_amd64/link in the archive"
for f in bin/go bin/gofmt bin/mavericks-cross-clang lib/librecaulk.a go.env build-info-linux-cross.txt mavergreen.plist; do
  grep -q "^$p/$f$" "$t/list" || fail "no $f in the archive"
done
echo "ok: layout"

# spec: build/build-linux-cross.sh -- the archive's own mavergreen.plist: the cross pkg's identity at this version, requiring clang22 from the
#       first release with dsymutil and sdk109 (what the Linux wrapper calls), never the Mac's clang22-cross or Longboat
tar -xzf "$tb" -C "$t" "$p/mavergreen.plist" || fail "cannot extract mavergreen.plist"
pl="$t/$p/mavergreen.plist"
pkey() { awk -v k="<key>$1</key>" 'f { sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>.*$/, ""); print; exit } index($0, k) { f = 1 }' "$pl"; }
[ "$(pkey identifier)" = "dev.mavergreen.golang.$root" ] || fail "plist identifier is '$(pkey identifier)', want dev.mavergreen.golang.$root"
[ "$(pkey product)" = "$root" ] || fail "plist product is '$(pkey product)', want $root"
[ "$(pkey version)" = "$version" ] || fail "plist version is '$(pkey version)', want $version (the archive's)"
[ "$(pkey line)" = "$line-cross" ] || fail "plist line is '$(pkey line)', want $line-cross"
reqs=$(awk '/<key>requires<\/key>/ { f = 1; next } f && /<\/array>/ { exit } f && /<string>/ { sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>.*$/, ""); print }' "$pl" \
  | sed -e 's/&gt;/>/g' -e 's/&lt;/</g' -e 's/&amp;/\&/g' | tr '\n' ' ')
[ "$reqs" = "clang22>=22.1.8-mavericks.26 sdk109 " ] || fail "plist requires '$reqs', want 'clang22>=22.1.8-mavericks.26 sdk109'"
echo "ok: mavergreen.plist ($root $version, requires $reqs)"

# spec: build/build-linux-cross.sh -- the build record names the port version too (the port's UPSTREAM_VERSION)
tar -xzf "$tb" -C "$t" "$p/build-info-linux-cross.txt" || fail "cannot extract build-info"
grep -qx "port_version=$(tr -d "[:space:]" < "$here/UPSTREAM_VERSION")" "$t/$p/build-info-linux-cross.txt" || fail "build-info lacks port_version: $(cat "$t/$p/build-info-linux-cross.txt")"

# spec: build/build-linux-cross.sh -- the archive's bin/go is a Linux x86-64 program (ELF, e_machine 0x3e), whatever host built it
tar -xzf "$tb" -C "$t" "$p/bin/go" || fail "cannot extract bin/go"
hd=$(od -An -tx1 -N20 "$t/$p/bin/go" | tr -d ' \n')
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

# spec: build/build-linux-cross.sh -- install@v1 `products:` unpacks a Linux archive with shipyard's product-tar.py into
#       <root>/usr/local/mavergreen/go1NN-cross; it refuses any entry outside the product prefix
x="$t/root/usr/local/mavergreen/$root"
pt="${SHIPYARD_SCRIPTS:-}/product-tar.py"
if [ -n "${SHIPYARD_SCRIPTS:-}" ] && [ -f "$pt" ] && command -v python3 >/dev/null 2>&1; then
  mkdir -p "$t/root/usr/local/mavergreen"
  python3 "$pt" "$tb" "$root" "$(shasum -a 256 "$tb" | awk '{print $1}')" "$x" || fail "product-tar.py refused $tb"
  [ -x "$x/bin/go" ] && [ -f "$x/mavergreen.plist" ] || fail "product-tar.py left no bin/go and mavergreen.plist at $x"
  echo "ok: product-tar.py installs it at <root>/usr/local/mavergreen/$root"
else
  echo "skip: no python3 or no SHIPYARD_SCRIPTS/product-tar.py, so the archive is extracted with tar"
  mkdir -p "$t/x" && tar -xzf "$tb" -C "$t/x" || fail "cannot extract $tb"
  mkdir -p "$t/root/usr/local/mavergreen" && mv "$t/x/$p" "$x"
fi

cl="${MAVERGREEN_CLANG22:-/usr/local/mavergreen/clang22}"
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ] || [ ! -x "$cl/bin/clang" ] || [ ! -d /usr/local/mavergreen/sdk109/SDKs ]; then
  echo "skip: extract-and-build needs a Linux x86_64 host with clang22 ($cl) and sdk109"
  echo "PASS: linux-cross (layout only)"
  exit 0
fi

# spec: build/build-linux-cross.sh -- go.env names CC relative to GOROOT, and port patch 0020 resolves it there: no CC is set below
grep -q "^CC=bin/mavericks-cross-clang\$" "$x/go.env" || fail "go.env has no CC=bin/mavericks-cross-clang: $(tail -4 "$x/go.env" | tr '\n' ' ')"
want_cc="$x/bin/mavericks-cross-clang"

gorun() { env -i PATH="$x/bin:/usr/bin:/bin" HOME="$t" GOCACHE="${GC:-$t/cache}" GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=mod \
  MAVERGREEN_CLANG22="${MC:-$cl}" "$@"; }

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

# spec: build/build-linux-cross.sh -- a cgo program builds too: its C goes through the wrapper to clang22 and the 10.9 SDK
mkdir "$t/hellocgo" && cp "$here/tests/hello-cgo/main.go" "$t/hellocgo/" && printf 'module hellocgo\n\ngo 1.21\n' > "$t/hellocgo/go.mod"
( cd "$t/hellocgo" && gorun "$x/bin/go" build -o "$t/hellocgo.bin" . ) > "$t/cgo.out" 2>&1 || fail "cgo go build failed: $(cat "$t/cgo.out")"
"$cl/bin/llvm-nm" "$t/hellocgo.bin" | grep -q ' T __cgo_[0-9a-f]*_Cfunc_my_pid$' || fail "hello-cgo has no cgo stub for my_pid: its C part was not compiled in"
mv=$("$cl/bin/llvm-otool" -l "$t/hellocgo.bin" | awk '$1 == "cmd" { c = $2; next } c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { m = $2 } c == "LC_BUILD_VERSION" && $1 == "minos" { m = $2 } END { print m }')
[ "$mv" = 10.9 ] || fail "hello-cgo has minos '$mv', want 10.9"
echo "ok: hello-cgo is a 10.9 Mach-O with its C function"

# spec: build/write-wrappers.sh -- Review Focus 4: no clang22 where the wrapper looks, and `go build` fails naming clang22 (it
#       does not fall back to the default path)
rm -rf "$t/cache2"
rc=0
( cd "$t/hello" && MC=/nonexistent GC="$t/cache2" gorun "$x/bin/go" build -o "$t/hello2.bin" . ) > "$t/nobuild.out" 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "go build succeeded with MAVERGREEN_CLANG22=/nonexistent (it fell back to another clang22)"
grep -q 'clang22 is not installed' "$t/nobuild.out" || fail "the failure does not name clang22: $(cat "$t/nobuild.out")"
grep -q '/nonexistent/bin/clang' "$t/nobuild.out" || fail "the failure does not name /nonexistent/bin/clang: $(cat "$t/nobuild.out")"
echo "ok: absent clang22 fails naming it"
# spec: PORT.md, port patch 0020 -- the tree works wherever it is copied: moved to a path with a space, go env CC names the copy's own
#       wrapper (quoted, as Go quotes a CC with a space) and a cgo build links through it and the copy's own Recaulk (the original
#       is removed first, so no other Recaulk is there to find)
m="$t/moved copy"
cp -R "$x" "$m" || fail "cannot copy $x to $m"
got=$(env -i PATH=/usr/bin:/bin HOME="$t" GOTOOLCHAIN=local "$m/bin/go" env CC 2>&1)
[ "$got" = "'$m/bin/mavericks-cross-clang'" ] || fail "moved: go env CC is '$got', want '$m/bin/mavericks-cross-clang' quoted"
rm -rf "$x" "$t/hellocgo.bin"
( cd "$t/hellocgo" && x="$m" GC="$t/cache3" gorun "$m/bin/go" build -ldflags=-v -o "$t/hellocgo.bin" . ) > "$t/moved.out" 2>&1 || fail "moved: cgo go build failed: $(cat "$t/moved.out")"
grep -q 'host link:' "$t/moved.out" || fail "moved: darwin/amd64 did not link external: $(cat "$t/moved.out")"
"$cl/bin/llvm-nm" "$t/hellocgo.bin" | grep -q ' [Tt] _clock_gettime$' || fail "moved: hello-cgo does not define _clock_gettime: the copy's Recaulk was not linked"
"$cl/bin/llvm-nm" "$t/hellocgo.bin" | grep -q ' T __cgo_[0-9a-f]*_Cfunc_my_pid$' || fail "moved: hello-cgo has no cgo stub for my_pid"
echo "ok: a copy at '$m' builds cgo through its own wrapper and Recaulk"
echo "PASS: linux-cross"
