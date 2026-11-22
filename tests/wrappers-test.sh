#!/bin/sh
# platform: host-agnostic
here=$(cd "$(dirname "$0")/.." && pwd)
# spec: tests/fixtures/line-* are copies of what a line holds and stay out of the tarball, so this test skips there
ls -d "$here"/tests/fixtures/line-* >/dev/null 2>&1 || { echo "skip: no tests/fixtures/line-* (run from the tarball); this test needs the line fixtures"; exit 77; }
t=$(mktemp -d "${TMPDIR:-/tmp}/wrappers-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT
# spec: build/write-wrappers.sh -- the linux wrapper prints its own directory as pwd does, without a TMPDIR's doubled slash
t=$(cd "$t" && pwd)

fail() { echo "FAIL: $*"; exit 1; }
has() { grep -q -- "$2" "$1" || fail "$3: want '$2' in: $(cat "$1")"; }
hasnt() { grep -q -- "$2" "$1" && fail "$3: did not want '$2' in: $(cat "$1")"; return 0; }

fx="$here/tests/fixtures/line-127"

# spec: build/write-wrappers.sh -- MAVERGREEN_PREFIX is test-only: a fixture family prefix with argv-echoing clang22 and clang22-cross and an sdk109
P="$t/mg"
for c in clang22 clang22-cross; do
  mkdir -p "$P/$c/bin"
  printf '#!/bin/sh\necho "$0 $*"\n' > "$P/$c/bin/clang"; chmod +x "$P/$c/bin/clang"
done
mkdir -p "$P/sdk109/SDKs/MacOSX10.9.sdk"

# spec: build/write-wrappers.sh -- write <kind> <dir> [prefix] runs write-wrappers.sh on line 127; status in $rc, stderr in $t/err
write() {
  rc=0
  MAVERGREEN_PREFIX="${3:-$P}" MAVERICKS_WORK="$t/work" LINE_ROOT="$fx" sh "$here/build/write-wrappers.sh" "$1" "$2" >"$t/out" 2>"$t/err" || rc=$?
}

# spec: build/write-wrappers.sh -- check <kind> <wrapper name> <clang dir> <recaulk>: a -c/-E/-S call has no Recaulk; a link carries Recaulk,
#       lld and -Wl,-U; both target x86_64 10.9 against sdk109
check() {
  k=$1 n=$2 c=$3 r=$4
  w="$t/$k/bin/$n"
  [ -x "$w" ] || fail "$k: no executable $w"
  "$w" -c x.c -o x.o > "$t/c" || fail "$k: -c call failed"
  has "$t/c" "^$P/$c/bin/clang -no-canonical-prefixes --no-default-config --target=x86_64-apple-macos10.9 -isysroot $P/sdk109/SDKs/MacOSX10.9.sdk -mmacosx-version-min=10.9 -c x.c -o x.o\$" "$k -c call"
  hasnt "$t/c" librecaulk "$k -c call"; hasnt "$t/c" -Wl,-U "$k -c call"
  for f in -E -S; do "$w" $f x.c > "$t/c"; hasnt "$t/c" librecaulk "$k $f call"; done
  "$w" x.o -o x > "$t/l" || fail "$k: link call failed"
  has "$t/l" "^$P/$c/bin/clang " "$k link"
  has "$t/l" "-isysroot $P/sdk109/SDKs/MacOSX10.9.sdk" "$k link"
  has "$t/l" "-fuse-ld=lld --ld-path=$P/$c/bin/ld64.lld" "$k link"
  has "$t/l" " $r " "$k link"
  has "$t/l" "-Wl,-U,_xpc_date_create_from_current" "$k link"
  progs "$k" "$w" "$P/$c"
}

# spec: build/cc-wrapper.sh -- progs <kind> <wrapper> <clang prefix>: Go's darwin link asks `$CC <flags> --print-prog-name strip` (and dsymutil,
#       and ar for c-archive), the flag and the name as two arguments; every spelling is answered from the clang22 prefix, never the host
progs() {
  for tool in strip:llvm-strip dsymutil:dsymutil ar:llvm-ar; do
    n=${tool%%:*} want="$3/bin/${tool#*:}"
    for form in "--print-prog-name $n" "--print-prog-name=$n" "-print-prog-name=$n" "-print-prog-name $n"; do
      got=$("$2" -arch x86_64 $form) || fail "$1 $form: exit $?"
      [ "$got" = "$want" ] || fail "$1 $form: got '$got', want '$want'"
    done
  done
  got=$("$2" --print-prog-name ld) || fail "$1 --print-prog-name ld: exit $?"
  case "$got" in *"--print-prog-name ld"*) ;; *) fail "$1: other prog names are clang's to answer, got '$got'" ;; esac
}

# spec: build/write-wrappers.sh -- missing <kind> <name> <product> <hint> <env...>: with that product's clang absent, the wrapper exits 1 naming it and how to install it
missing() {
  k=$1 n=$2 prod=$3 hint=$4; shift 4
  rc=0; env "$@" "$t/$k/bin/$n" x.o -o x > "$t/m.out" 2> "$t/m.err" || rc=$?
  [ "$rc" = 1 ] || fail "$k with no $prod: exit $rc"
  has "$t/m.err" "$prod is not installed" "$k with no $prod"
  has "$t/m.err" "$hint" "$k with no $prod"
  [ ! -s "$t/m.out" ] || fail "$k with no $prod still ran a compiler: $(cat "$t/m.out")"
}

write native "$t/native"
[ "$rc" = 0 ] || fail "native: exit $rc: $(cat "$t/err")"
check native mavericks-clang clang22 /usr/local/mavergreen/go127/lib/librecaulk.a

write cross "$t/cross"
[ "$rc" = 0 ] || fail "cross: exit $rc: $(cat "$t/err")"
check cross mavericks-cross-clang clang22-cross /usr/local/mavergreen/go127-cross/lib/librecaulk.a

# spec: build/write-wrappers.sh -- the linux wrapper finds Recaulk in its own archive, wherever that is extracted, and clang22 at
#       MAVERGREEN_CLANG22 when set, else at the family prefix
write linux "$t/linux"
[ "$rc" = 0 ] || fail "linux: exit $rc: $(cat "$t/err")"
check linux mavericks-cross-clang clang22 "$t/linux/lib/librecaulk.a"
mv "$t/linux" "$t/elsewhere"; mkdir -p "$t/linux"
"$t/elsewhere/bin/mavericks-cross-clang" x.o -o x > "$t/l"
has "$t/l" " $t/elsewhere/lib/librecaulk.a " "relocated linux archive"
# spec: build/write-wrappers.sh -- the linux wrapper needs no dirname: with PATH=/bin (10.9 keeps dirname in /usr/bin) it still finds its Recaulk
PATH=/bin "$t/elsewhere/bin/mavericks-cross-clang" x.o -o x > "$t/l" 2> "$t/e" || fail "linux wrapper with PATH=/bin: $(cat "$t/e")"
[ ! -s "$t/e" ] || fail "linux wrapper with PATH=/bin: $(cat "$t/e")"
has "$t/l" " $t/elsewhere/lib/librecaulk.a " "linux wrapper with PATH=/bin"
mkdir -p "$t/other/bin"; printf '#!/bin/sh\necho "OTHER $*"\n' > "$t/other/bin/clang"; chmod +x "$t/other/bin/clang"
MAVERGREEN_CLANG22="$t/other" "$t/elsewhere/bin/mavericks-cross-clang" -c x.c > "$t/c"
has "$t/c" "^OTHER " "MAVERGREEN_CLANG22"
rm -rf "$t/linux"; mv "$t/elsewhere" "$t/linux"

# spec: build/write-wrappers.sh -- each wrapper fails, naming the product and its install command, when its clang22 is absent
rm -rf "$P/clang22" "$P/clang22-cross"
missing native mavericks-clang clang22 "sudo installer -pkg clang22-22.1.8-mavericks.25.pkg"
missing cross mavericks-cross-clang clang22-cross "sudo installer -pkg clang22-cross-22.1.8-mavericks.25.pkg"
missing linux mavericks-cross-clang clang22 "install@v1 products: clang22@22.1.8-mavericks.25"
missing linux mavericks-cross-clang clang22 "install@v1 products: clang22" MAVERGREEN_CLANG22="$t/nowhere"

# spec: build/write-wrappers.sh -- a missing sdk109 names Longboat (macOS) or install@v1 (Linux)
mkdir -p "$P/clang22/bin"; printf '#!/bin/sh\necho "$0 $*"\n' > "$P/clang22/bin/clang"; chmod +x "$P/clang22/bin/clang"
rm -rf "$P/sdk109"
missing native mavericks-clang sdk109 "sudo longboat sdk install 10.9"
missing linux mavericks-cross-clang sdk109 "install@v1 products: sdk109"

# spec: build/write-wrappers.sh -- usage errors exit 2
write bogus "$t/bogus"; [ "$rc" = 2 ] || fail "unknown kind: exit $rc"
write native ""; [ "$rc" = 2 ] || fail "no dir: exit $rc"

echo "PASS: wrappers"
