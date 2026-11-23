#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- a shipped toolchain works wherever it is copied: each wrapper (build/write-wrappers.sh) finds Recaulk
#       beside itself, and its clang22 and SDK at the family prefix or at MAVERGREEN_CLANG22 / MAVERGREEN_CLANG22_CROSS / MAVERGREEN_SDK109,
#       all through paths that hold a space. Stub compilers print their argv; no built toolchain is needed, and the line is made here.
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/relocate-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT
# spec: build/env.sh -- spelled as pwd spells it, so a Mac TMPDIR's doubled slash is not in the paths the wrappers print
t=$(cd "$t" && pwd)

fail() { echo "FAIL: $*"; exit 1; }
# spec: tests/relocate-test.sh -- arg <file> <value> <what>: the stub saw <value> as one whole argument
arg() { grep -qxF -- "$2" "$1" || fail "$3: no argument '$2' in: $(tr '\n' '|' < "$1")"; }

# spec: build/env.sh -- a minimal line: the inputs env.sh reads, and shipyard's scripts located (write-wrappers.sh never runs them)
L="$t/line"
mkdir -p "$L/components/recaulk" "$L/components/clang22"
echo 1.27.4 > "$L/UPSTREAM_VERSION"; echo 1.27.4-mavericks.1 > "$L/VERSION"
echo 3.2.9 > "$L/components/recaulk/version"; echo 22.1.8-mavericks.26 > "$L/components/clang22/version"
printf 'CROSS_MIN_OS=11.0\nCA_SHA256=0\n' > "$L/line.env"
[ -n "${SHIPYARD_SCRIPTS:-}" ] && [ -d "$SHIPYARD_SCRIPTS" ] || { mkdir "$t/ship"; SHIPYARD_SCRIPTS="$t/ship"; }
export SHIPYARD_SCRIPTS

# spec: tests/relocate-test.sh -- stub <clang22 dir>: a clang that prints its own path and each argument on a line
stub() { mkdir -p "$1/bin"; printf '#!/bin/sh\nfor a in "$0" "$@"; do printf "%%s\\n" "$a"; done\n' > "$1/bin/clang"; chmod +x "$1/bin/clang"; }
P="$t/family prefix"
stub "$P/clang22"; stub "$P/clang22-cross"; mkdir -p "$P/sdk109/SDKs/MacOSX10.9.sdk"
stub "$t/other clang22"; stub "$t/other cross"; mkdir -p "$t/other sdk/SDKs/MacOSX10.9.sdk"

for k in native cross linux; do
  case $k in
    native) n=mavericks-clang c=clang22 o="$t/other clang22" ov=MAVERGREEN_CLANG22 ;;
    cross) n=mavericks-cross-clang c=clang22-cross o="$t/other cross" ov=MAVERGREEN_CLANG22_CROSS ;;
    linux) n=mavericks-cross-clang c=clang22 o="$t/other clang22" ov=MAVERGREEN_CLANG22 ;;
  esac
  MAVERGREEN_PREFIX="$P" MAVERICKS_WORK="$t/work" LINE_ROOT="$L" sh "$here/build/write-wrappers.sh" $k "$t/built" >"$t/out" 2>&1 \
    || fail "$k: write-wrappers.sh: $(cat "$t/out")"
  # spec: build/write-wrappers.sh -- the tree is moved to a path with a space; the wrapper names nothing of where it was written
  d="$t/moved toolchain/$k"
  mkdir -p "$t/moved toolchain" && mv "$t/built" "$d"
  grep -F "$t/built" "$d/bin/$n" >/dev/null && fail "$k: the wrapper names the directory it was written in"
  w="$d/bin/$n"

  env -u MAVERGREEN_CLANG22 -u MAVERGREEN_CLANG22_CROSS -u MAVERGREEN_SDK109 "$w" x.o -o x > "$t/l" || fail "$k: link failed"
  [ "$(sed -n 1p "$t/l")" = "$P/$c/bin/clang" ] || fail "$k: ran $(sed -n 1p "$t/l"), want $P/$c/bin/clang"
  arg "$t/l" "$d/lib/librecaulk.a" "$k moved: Recaulk beside the wrapper"
  arg "$t/l" "$P/sdk109/SDKs/MacOSX10.9.sdk" "$k moved: default SDK"
  arg "$t/l" "--ld-path=$P/$c/bin/ld64.lld" "$k moved: lld"
  "$w" -c x.c > "$t/c" || fail "$k: -c failed"
  grep -q librecaulk "$t/c" && fail "$k: a -c call carries Recaulk"

  # spec: build/write-wrappers.sh -- called by a relative path, and with PATH=/bin (10.9 has no dirname there), Recaulk is still absolute
  ( cd "$d" && PATH=/bin bin/$n x.o -o x ) > "$t/l" 2> "$t/e" || fail "$k relative, PATH=/bin: $(cat "$t/e")"
  [ ! -s "$t/e" ] || fail "$k relative, PATH=/bin: $(cat "$t/e")"
  arg "$t/l" "$d/lib/librecaulk.a" "$k relative, PATH=/bin"

  # spec: build/write-wrappers.sh -- an exported CDPATH that holds a matching ".." does not move the cd, nor add its echo to the path
  mkdir -p "$t/decoy/bin"
  ( cd "$d" && CDPATH="$t/decoy:." && export CDPATH && bin/$n x.o -o x ) > "$t/l" 2> "$t/e" || fail "$k with CDPATH: $(cat "$t/e")"
  arg "$t/l" "$d/lib/librecaulk.a" "$k relative, CDPATH exported"

  # spec: build/write-wrappers.sh -- the overrides, each at a path with a space
  env "$ov=$o" MAVERGREEN_SDK109="$t/other sdk" "$w" x.o -o x > "$t/l" || fail "$k: link with overrides failed"
  [ "$(sed -n 1p "$t/l")" = "$o/bin/clang" ] || fail "$k: $ov: ran $(sed -n 1p "$t/l"), want $o/bin/clang"
  arg "$t/l" "--ld-path=$o/bin/ld64.lld" "$k $ov: lld"
  arg "$t/l" "$t/other sdk/SDKs/MacOSX10.9.sdk" "$k MAVERGREEN_SDK109"
  arg "$t/l" "$d/lib/librecaulk.a" "$k with overrides: Recaulk"

  # spec: build/write-wrappers.sh -- an absent override fails naming the path it looked at and the override
  rc=0; env "$ov=$t/nowhere" "$w" -c x.c > "$t/m" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -qF "no $t/nowhere/bin/clang" "$t/m" && grep -q "set $ov" "$t/m" || fail "$k: absent $ov: exit $rc: $(cat "$t/m")"
  rc=0; MAVERGREEN_SDK109="$t/no sdk" "$w" -c x.c > "$t/m" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -qF "no $t/no sdk/SDKs/MacOSX10.9.sdk" "$t/m" && grep -q 'set MAVERGREEN_SDK109' "$t/m" \
    || fail "$k: absent MAVERGREEN_SDK109: exit $rc: $(cat "$t/m")"
  echo "ok: $k wrapper relocates"
done

# spec: PORT.md, the build chain -- the cross wrapper's compiler is clang22-cross: MAVERGREEN_CLANG22 does not steer it
MAVERGREEN_CLANG22="$t/other clang22" "$t/moved toolchain/cross/bin/mavericks-cross-clang" -c x.c > "$t/c"
[ "$(sed -n 1p "$t/c")" = "$P/clang22-cross/bin/clang" ] || fail "cross: MAVERGREEN_CLANG22 steered it to $(sed -n 1p "$t/c")"
echo "ok: MAVERGREEN_CLANG22 leaves the cross wrapper alone"
echo "PASS: relocate"
