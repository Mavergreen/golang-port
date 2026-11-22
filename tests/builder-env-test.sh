#!/bin/sh
# platform: host-agnostic
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/builder-env-test.XXXXXX") || exit 1
[ -d "$t" ] || exit 1
trap 'rm -rf "$t"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
has() { grep -q -- "$2" "$1" || fail "$3: want '$2' in: $(cat "$1")"; }
hasnt() { grep -q -- "$2" "$1" && fail "$3: did not want '$2' in: $(cat "$1")"; return 0; }

# spec: build/build-builder.sh -- a fixture family prefix (MAVERGREEN_PREFIX is test-only) and a stub fetch/apply/make.bash:
#       the stub fetch leaves a "pristine" tree whose make.bash records its environment and arguments and makes bin/go
want_clang=22.1.8-mavericks.25
P="$t/mg"
mkdir -p "$P/clang22/bin" "$P/sdk109/SDKs/MacOSX10.9.sdk" "$P/recaulk/lib"
printf '#!/bin/sh\necho "Non-fat file: $2 is architecture: x86_64"\n' > "$P/clang22/bin/llvm-lipo"
for x in llvm-strip dsymutil llvm-ar; do printf "#!/bin/sh\n" > "$P/clang22/bin/$x"; done
chmod +x "$P/clang22/bin/llvm-lipo" "$P/clang22/bin/llvm-strip" "$P/clang22/bin/dsymutil" "$P/clang22/bin/llvm-ar"
: > "$P/recaulk/lib/librecaulk.a"
mkplist() { printf '<plist><dict>\n<key>version</key>\n<string>%s</string>\n</dict></plist>\n' "$2" > "$1/mavergreen.plist"; }
fx0="$here/tests/fixtures/line-127"
mkplist "$P/clang22" "$want_clang"; mkplist "$P/sdk109" 1; mkplist "$P/recaulk" "$(tr -d ' \t\r\n' < "$fx0/components/recaulk/version")"

mkdir -p "$t/boot/bin"; printf '#!/bin/sh\n' > "$t/boot/bin/go"; chmod +x "$t/boot/bin/go"
cat > "$t/fetch" <<'EOS'
#!/bin/sh
echo x >> "$FIXTURE_COUNT/fetches"
rm -rf "$WORK/go"; mkdir -p "$WORK/go/src"
cat > "$WORK/go/src/make.bash" <<'EOM'
#!/bin/sh
echo x >> "$FIXTURE_COUNT/makes"
env > "$FIXTURE_COUNT/env"
echo "$*" > "$FIXTURE_COUNT/args"
echo "$PWD" > "$FIXTURE_COUNT/cwd"
mkdir -p ../bin; echo '#!/bin/sh' > ../bin/go; chmod +x ../bin/go
mkdir -p ../pkg/tool/stub_os; : > ../pkg/tool/stub_os/vet; : > ../pkg/tool/stub_os/compile
EOM
chmod +x "$WORK/go/src/make.bash"
EOS
printf '#!/bin/sh\necho x >> "$FIXTURE_COUNT/applies"\n' > "$t/apply"

# spec: build/build-builder.sh -- run <line> [bootstrap]: runs the script on <line>; stderr in $t/err, status in $rc
run() {
  rc=0
  FIXTURE_COUNT="$t/count" MAVERGREEN_PREFIX="$P" MAVERICKS_WORK="$t/work" LINE_ROOT="$1" \
    GOROOT_BOOTSTRAP="${2-$t/boot}" BUILDER_FETCH_GO="$t/fetch" BUILDER_APPLY_PATCHES="$t/apply" \
    sh "$here/build/build-builder.sh" >"$t/out" 2>"$t/err" || rc=$?
}
count() { [ -f "$t/count/$1" ] && wc -l < "$t/count/$1" | tr -d ' ' || echo 0; }

rm -rf "$t/line"; cp -R "$fx0" "$t/line"; mkdir -p "$t/count"

# spec: build/build-builder.sh -- stray compiler/target variables are unset, said so on stderr, and never reach make.bash
CC=gcc CC_FOR_TARGET=x GOOS=linux CGO_ENABLED=1 CGO_CFLAGS=-g GOHOSTARCH=arm64 run "$t/line"
[ "$rc" = 0 ] || fail "first run: exit $rc: $(cat "$t/err")"
[ "$(count makes)" = 1 ] || fail "first run: make.bash ran $(count makes) times"
for v in CC CC_FOR_TARGET GOOS GOARCH GOHOSTOS GOHOSTARCH CGO_ENABLED CGO_CFLAGS; do
  hasnt "$t/count/env" "^$v=" "make.bash env"
done
has "$t/err" 'unset.*CC_FOR_TARGET' "stderr names what was unset"
has "$t/err" 'unset.*CGO_CFLAGS' "stderr names CGO_CFLAGS"

# spec: build/build-builder.sh -- the wrapper's directory leads PATH; the darwin/amd64 external-link default; bootstrap; ./make.bash -v from src
has "$t/count/env" "^PATH=$t/work/cc/bin:" "PATH"
has "$t/count/env" '^GO_EXTLINK_ENABLED=darwin/amd64$' "GO_EXTLINK_ENABLED"
has "$t/count/env" "^GOROOT_BOOTSTRAP=$t/boot\$" "GOROOT_BOOTSTRAP"
[ "$(cat "$t/count/args")" = "-v" ] || fail "make.bash args: $(cat "$t/count/args")"
case "$(cat "$t/count/cwd")" in */work/go/src) ;; *) fail "make.bash cwd: $(cat "$t/count/cwd")" ;; esac
[ -x "$t/work/go/bin/go" ] || fail "no builder go"
has "$t/work/builder.key" '^go=1\.27\.' "key: go version"
has "$t/work/builder.key" "^clang22=$want_clang\$" "key: clang22 version"
has "$t/work/builder.key" "^host=$(uname -sm)\$" "key: uname -sm"
has "$t/work/builder.key" '^patches=[0-9a-f]\{64\}$' "key: patch set sha256"
[ "$(cat "$t/work/builder.tools")" = "compile
vet" ] || fail "builder.tools: $(cat "$t/work/builder.tools")"

# spec: build/build-builder.sh -- same inputs: reused, make.bash not called, and it says so
run "$t/line"
[ "$rc" = 0 ] || fail "second run: exit $rc: $(cat "$t/err")"
[ "$(count makes)" = 1 ] || fail "same key: make.bash ran again"
has "$t/err" 'reusing' "stderr says the builder is reused"

# spec: build/build-builder.sh -- a builder without its recorded tool list is rebuilt
rm "$t/work/builder.tools"
run "$t/line"
[ "$rc" = 0 ] || fail "no builder.tools: exit $rc: $(cat "$t/err")"
[ "$(count makes)" = 2 ] || fail "no builder.tools did not rebuild (makes=$(count makes))"
[ -f "$t/work/builder.tools" ] || fail "rebuild left no builder.tools"

# spec: build/build-builder.sh -- one changed patch byte rebuilds, from a fresh fetch
printf '\n' >> "$t/line/patches/0016-root-hook.patch"
run "$t/line"
[ "$rc" = 0 ] || fail "changed patch: exit $rc: $(cat "$t/err")"
[ "$(count makes)" = 3 ] || fail "changed patch byte did not rebuild (makes=$(count makes))"
[ "$(count fetches)" = 3 ] || fail "rebuild did not start from a fresh fetch"

# spec: build/build-builder.sh -- a make.bash that fails leaves no key, so the half-built tree is never reused
cat > "$t/fetchfail" <<'EOS'
#!/bin/sh
rm -rf "$WORK/go"; mkdir -p "$WORK/go/src"
printf '#!/bin/sh\nexit 1\n' > "$WORK/go/src/make.bash"; chmod +x "$WORK/go/src/make.bash"
EOS
printf '\n' >> "$t/line/patches/0016-root-hook.patch"
rc=0; FIXTURE_COUNT="$t/count" MAVERGREEN_PREFIX="$P" MAVERICKS_WORK="$t/work" LINE_ROOT="$t/line" GOROOT_BOOTSTRAP=$t/boot \
  BUILDER_FETCH_GO="$t/fetchfail" BUILDER_APPLY_PATCHES="$t/apply" sh "$here/build/build-builder.sh" >"$t/out" 2>"$t/err" || rc=$?
[ "$rc" != 0 ] || fail "failing make.bash exited 0"
[ ! -f "$t/work/builder.key" ] || fail "key survives a failed make.bash"

echo "PASS: builder-env"
