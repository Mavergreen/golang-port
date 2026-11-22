#!/bin/sh
# platform: host-agnostic
here=$(cd "$(dirname "$0")/.." && pwd)
# spec: tests/fixtures/line-* are copies of what a line holds and stay out of the tarball, so this test skips there
ls -d "$here"/tests/fixtures/line-* >/dev/null 2>&1 || { echo "skip: no tests/fixtures/line-* (run from the tarball); this test needs the line fixtures"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/c-toolchain-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

fx="$here/tests/fixtures/line-127"
want_clang=22.1.8-mavericks.25
want_recaulk=$(tr -d ' \t\r\n' < "$fx/components/recaulk/version")

# spec: build/c-toolchain.sh -- MAVERGREEN_PREFIX is test-only; it relocates every product the script checks
# spec: build/c-toolchain.sh -- mkplist <dir> <version> writes a fixture product mavergreen.plist
mkplist() {
  cat > "$1/mavergreen.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>identifier</key>
  <string>dev.mavergreen.fixture</string>
  <key>version</key>
  <string>$2</string>
</dict>
</plist>
PL
}

# spec: build/c-toolchain.sh -- mkprefix <dir> [clang-dir] builds a fixture family prefix: an argv-echoing clang, an llvm-lipo reporting x86_64, sdk109 and recaulk at the pins
mkprefix() {
  p=$1; c=${2:-clang22}
  mkdir -p "$p/$c/bin" "$p/sdk109/SDKs/MacOSX10.9.sdk" "$p/recaulk/lib"
  printf '#!/bin/sh\necho "$0 $*"\n' > "$p/$c/bin/clang"
  printf '#!/bin/sh\necho "Non-fat file: $2 is architecture: x86_64"\n' > "$p/$c/bin/llvm-lipo"
  for x in llvm-strip dsymutil llvm-ar; do printf '#!/bin/sh\n' > "$p/$c/bin/$x"; chmod +x "$p/$c/bin/$x"; done
  chmod +x "$p/$c/bin/clang" "$p/$c/bin/llvm-lipo"
  : > "$p/recaulk/lib/librecaulk.a"
  mkplist "$p/$c" "$want_clang"; mkplist "$p/sdk109" 20261012.2; mkplist "$p/recaulk" "$want_recaulk"
}

# spec: build/c-toolchain.sh -- run <prefix> [args] runs c-toolchain.sh on line 127; stdout in $t/out, stderr in $t/err, status in $rc; the pin mode is T_CI and T_STRICT, never the caller environment
run() {
  p=$1; shift
  rc=0
  CI="${T_CI-}" MAVERGREEN_STRICT_PINS="${T_STRICT-}" MAVERGREEN_PREFIX=$p MAVERICKS_WORK="$t/work" LINE_ROOT="$fx" sh "$here/build/c-toolchain.sh" "$@" >"$t/out" 2>"$t/err" || rc=$?
}

has() { grep -q -- "$2" "$1" || fail "$3: want '$2' in: $(cat "$1")"; }
hasnt() { grep -q -- "$2" "$1" && fail "$3: did not want '$2' in: $(cat "$1")"; return 0; }

# spec: build/c-toolchain.sh -- a good prefix prints the wrapper path; -c has no Recaulk, a link has it
P="$t/mg"; mkprefix "$P"
run "$P"
[ "$rc" = 0 ] || fail "good prefix: exit $rc: $(cat "$t/err")"
cc=$(cat "$t/out")
[ "$cc" = "$t/work/cc/bin/clang" ] || fail "wrapper path: got $cc"
[ -x "$cc" ] || fail "wrapper not executable"
"$cc" -c x.c -o x.o > "$t/c" || fail "wrapper -c"
has "$t/c" "^$P/clang22/bin/clang -no-canonical-prefixes --no-default-config --target=x86_64-apple-macos10.9 -isysroot $P/sdk109/SDKs/MacOSX10.9.sdk -mmacosx-version-min=10.9 -c x.c -o x.o\$" "-c call"
hasnt "$t/c" recaulk "-c call"
for f in -E -S; do
  "$cc" $f x.c > "$t/c"; hasnt "$t/c" recaulk "$f call"
done
"$cc" x.o -o x > "$t/l" || fail "wrapper link"
has "$t/l" "^$P/clang22/bin/clang " "link call"
has "$t/l" -fuse-ld=lld "link call"
has "$t/l" "--ld-path=$P/clang22/bin/ld64.lld" "link call"
has "$t/l" "$P/recaulk/lib/librecaulk.a" "link call"
has "$t/l" -Wl,-U,_xpc_date_create_from_current "link call"
has "$t/l" "-isysroot $P/sdk109/SDKs/MacOSX10.9.sdk" "link call"
# spec: build/c-toolchain.sh -- Go's darwin link asks the wrapper for strip, dsymutil and ar (--print-prog-name); it answers from clang22, so no
#       host tool (Apple's strip on 10.9, GNU's on Linux) is ever used, and nothing beside the wrapper stands in for one
for x in strip:llvm-strip dsymutil:dsymutil ar:llvm-ar; do
  got=$("$cc" -arch x86_64 --print-prog-name "${x%%:*}")
  [ "$got" = "$P/clang22/bin/${x#*:}" ] || fail "build wrapper --print-prog-name ${x%%:*}: got $got"
done
[ ! -e "$t/work/cc/bin/strip" ] || fail "a strip beside the wrapper: one mechanism, the wrapper's answer"
# spec: build/c-toolchain.sh -- $WORK/cc/vars: the paths the wrapper was written with, for the build scripts to source
[ "$( . "$t/work/cc/vars"; printf '%s|%s|%s' "$cc_prefix" "$sdk" "$recaulk")" = "$P/clang22|$P/sdk109/SDKs/MacOSX10.9.sdk|$P/recaulk/lib/librecaulk.a" ] || fail "vars: $(cat "$t/work/cc/vars")"
# spec: build/c-toolchain.sh -- a clang22 prefix without dsymutil, llvm-strip or llvm-ar refuses, naming the tool, instead of leaving Go to find the host's
for tool in dsymutil llvm-strip llvm-ar; do
  Q="$t/mg-no-$tool"; mkprefix "$Q"; rm "$Q/clang22/bin/$tool"
  run "$Q"
  [ "$rc" = 1 ] || fail "clang22 without $tool: exit $rc"
  has "$t/err" "$tool" "clang22 without $tool"
done
# spec: build/c-toolchain.sh -- no product uses sdk113 (the updater's SDK comes from shipyard), so the flag is gone and nothing records it
run "$P" --with-sdk113
[ "$rc" = 2 ] || fail "--with-sdk113 is not an option any more: exit $rc"
has "$t/err" "unknown argument --with-sdk113" "--with-sdk113"

# spec: build/c-toolchain.sh -- strict pins (the default here is T_STRICT=1) refuse version drift, naming both versions and the install command
T_STRICT=1
Q="$t/mg-clang"; mkprefix "$Q"; mkplist "$Q/clang22" 22.1.7-mavericks.1
run "$Q"
[ "$rc" = 1 ] || fail "wrong clang22: exit $rc"
for s in clang22 22.1.7-mavericks.1 "$want_clang" "provision-linux.sh clang22@$want_clang"; do has "$t/err" "$s" "wrong clang22"; done

Q="$t/mg-recaulk"; mkprefix "$Q"; mkplist "$Q/recaulk" 20200101.9
run "$Q"
[ "$rc" = 1 ] || fail "wrong recaulk: exit $rc"
for s in recaulk 20200101.9 "$want_recaulk" "provision-linux.sh recaulk@$want_recaulk"; do has "$t/err" "$s" "wrong recaulk"; done

# spec: build/c-toolchain.sh -- a missing x86_64 slice refuses
unset T_STRICT
Q="$t/mg-slice"; mkprefix "$Q"; printf '#!/bin/sh\necho "Non-fat file: $2 is architecture: arm64"\n' > "$Q/clang22/bin/llvm-lipo"
run "$Q"
[ "$rc" = 1 ] || fail "no x86_64 slice: exit $rc"
has "$t/err" x86_64 "no x86_64 slice"

# spec: build/c-toolchain.sh -- missing products refuse in every mode
Q="$t/mg-nosdk"; mkprefix "$Q"; rm -rf "$Q/sdk109/SDKs"
run "$Q"
[ "$rc" = 1 ] || fail "missing sdk109: exit $rc"
has "$t/err" sdk109 "missing sdk109"; has "$t/err" "longboat sdk install 10.9" "missing sdk109"
Q="$t/mg-noclang"; mkprefix "$Q"; rm -rf "$Q/clang22"
run "$Q"
[ "$rc" = 1 ] || fail "missing clang22: exit $rc"
has "$t/err" clang22 "missing clang22"
Q="$t/mg-norec"; mkprefix "$Q"; rm -rf "$Q/recaulk"
run "$Q"
[ "$rc" = 1 ] || fail "missing recaulk: exit $rc"
has "$t/err" recaulk "missing recaulk"

# spec: build/c-toolchain.sh -- on Apple Silicon (a uname stub) clang22-cross stands in for clang22, with a note
mkdir "$t/bin"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; *) echo Darwin;; esac\n' > "$t/bin/uname"; chmod +x "$t/bin/uname"
A="$t/mg-arm"; mkprefix "$A" clang22-cross
OLDPATH=$PATH; PATH="$t/bin:$PATH"
run "$A"
PATH=$OLDPATH
[ "$rc" = 0 ] || fail "arm64 Darwin with clang22-cross: exit $rc: $(cat "$t/err")"
has "$t/err" "interface-equal, not byte-equal" "arm64 note"
"$(cat "$t/out")" -c x.c > "$t/c"
has "$t/c" "^$A/clang22-cross/bin/clang -no-canonical-prefixes" "arm64 wrapper"
mkdir "$t/bin-linux"
printf '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; *) echo Linux;; esac\n' > "$t/bin-linux/uname"; chmod +x "$t/bin-linux/uname"
PATH="$t/bin-linux:$PATH"
run "$A"
PATH=$OLDPATH
[ "$rc" = 1 ] || fail "clang22-cross is not accepted off arm64 Darwin: exit $rc"
# spec: build/c-toolchain.sh -- the pin modes: strict refuses drift, lenient warns once per drifted product and goes on
D="$t/mg-drift"; mkprefix "$D"; mkplist "$D/clang22" 22.1.7-mavericks.1; mkplist "$D/recaulk" 20200101.9
T_CI=true; T_STRICT=
run "$D"; [ "$rc" = 1 ] || fail "CI=true with drift: exit $rc"
T_CI=; T_STRICT=1
run "$D"; [ "$rc" = 1 ] || fail "MAVERGREEN_STRICT_PINS=1 with drift: exit $rc"
T_CI=true; T_STRICT=0
run "$D"; [ "$rc" = 0 ] || fail "CI=true, STRICT_PINS=0, drift: exit $rc: $(cat "$t/err")"
has "$t/err" warning "STRICT_PINS=0"
T_CI=; T_STRICT=
run "$D"; [ "$rc" = 0 ] || fail "dev box with drift: exit $rc: $(cat "$t/err")"
[ "$(grep -c "clang22 at" "$t/err")" = 1 ] || fail "want one clang22 warning: $(cat "$t/err")"
[ "$(grep -c "recaulk at" "$t/err")" = 1 ] || fail "want one recaulk warning: $(cat "$t/err")"
for s in 22.1.7-mavericks.1 "$want_clang" 20200101.9 "$want_recaulk" match; do has "$t/err" "$s" "drift warning"; done
[ "$(cat "$t/work/cc/versions")" = "clang22=22.1.7-mavericks.1
recaulk=20200101.9
sdk109=20261012.2
pins=lenient" ] || fail "versions (lenient): $(cat "$t/work/cc/versions")"
run "$P"; [ "$rc" = 0 ] || fail "versions run: $rc"
hasnt "$t/work/cc/versions" sdk113 "versions"; has "$t/work/cc/versions" "^pins=lenient\$" "versions"
T_STRICT=1; run "$P"; [ "$rc" = 0 ] || fail "strict, no drift: $rc"
has "$t/work/cc/versions" "^pins=strict\$" "versions"
echo "ok: c-toolchain"
