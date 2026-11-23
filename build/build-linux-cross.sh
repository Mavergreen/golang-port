#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/build-linux-cross.sh: go1NN-cross-<version>-linux-x86_64.tar.gz, the toolchain a Linux CI runner
#       uses to build 10.9 darwin/amd64 programs (product go1NN-cross; install@v1 `products:` installs it at /usr/local/mavergreen/go1NN-cross).
#       usage: LINE_ROOT=<line checkout> [GOROOT_BOOTSTRAP=<go>] [LINUX_CROSS_OUT=<dir>] [SOURCE_DATE_EPOCH=<n>] sh build/build-linux-cross.sh
#       Leaves $WORK/staging-linux/opt/mavergreen/go1NN-cross, and writes the archive and build-info-linux-cross.txt to $LINUX_CROSS_OUT (default
#       $WORK/out); prints the archive's path. Runs build-builder.sh itself (which reuses a matching builder).
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
. "$PORT_DIR/build/env.sh" || exit $?
TL_NAME=build-linux-cross.sh
sh "$PORT_DIR/build/build-builder.sh"
# spec: PORT.md, the build chain -- the archive's mtimes are the line's commit time unless SOURCE_DATE_EPOCH is set: source-date-epoch.sh reads MAVERICKS_ROOT.
: "${MAVERICKS_ROOT:=$LINE_ROOT}"
export MAVERICKS_ROOT
. "$PORT_DIR/build/toolchain-lib.sh"
RECAULK_LIB="$(tl_cc_var recaulk)"
root="go$GO_LINE-cross"
# spec: PORT.md, the build chain -- clang22 22.1.8-mavericks.26 is the first release whose prefix has dsymutil, which the wrapper answers for
LINUX_CLANG22_FLOOR=22.1.8-mavericks.26
# spec: PORT.md, the build chain -- the archive holds the linux/amd64 toolchain, rebuilt from the builder the same way on EVERY host
#       (cgo off: Go internal-links it, and -trimpath keeps the build host's paths out), so a Linux CI box, a 10.9 Mac and an Apple
#       Silicon one produce the same bytes. make.bash's own linux/amd64 binaries are not staged: they carry another build
#       configuration (101 MB with DWARF against 70 MB here). On a Linux x86_64 host this install replaces the builder's own bin/
#       and pkg/tool in place (same Go version, so later builds are unaffected), as build-native.sh does on 10.9; elsewhere it
#       writes bin/linux_amd64 and pkg/tool/linux_amd64. tl_stage takes only the toolchain, never a host binary.
tl_go_env
GOOS=linux GOARCH=amd64 CGO_ENABLED=0
export GOOS GOARCH CGO_ENABLED
( cd "$WORK/go/src" && "$WORK/go/bin/go" install -trimpath cmd )
unset GOOS GOARCH CGO_ENABLED

# spec: PORT.md, the build chain -- staged first where its pkg would put it, so shipyard's stage_product.sh renders the manifest as it does for
#       every pkg; the archive then holds it under opt/mavergreen/go1NN-cross, the one prefix shipyard's product-tar.py accepts.
stage="$WORK/staging-linux"
pstage="$WORK/staging-linux-pkg"
dest="$pstage$CROSS_PREFIX"
rm -rf "$stage" "$pstage"
mkdir -p "$stage/opt/mavergreen"
tl_stage linux amd64 "$dest"
mkdir -p "$dest/lib"
cp "$RECAULK_LIB" "$dest/lib/librecaulk.a"
sh "$PORT_DIR/build/write-wrappers.sh" linux "$dest"
# spec: PORT.md, the build chain -- out of the box this toolchain targets 10.9 darwin/amd64. CC is relative to GOROOT, which port patch
#       0020 resolves, so an archive extracted anywhere finds its own wrapper with no CC set (the environment still beats go.env).
{
  echo "GOOS=darwin"
  echo "GOARCH=amd64"
  echo "CGO_ENABLED=1"
  echo "CC=bin/mavericks-cross-clang"
} >> "$dest/go.env"

# spec: PORT.md, the build chain -- bin/go is a Linux x86-64 ELF file (e_machine 0x3e); a Mach-O or another architecture fails here
hd="$(od -An -tx1 -N20 "$dest/bin/go" | tr -d ' \n')"
case "$hd" in 7f454c46*) ;; *) tl_die "$dest/bin/go is not an ELF file ($hd)" ;; esac
[ "$(printf '%s' "$hd" | cut -c37-40)" = 3e00 ] || tl_die "$dest/bin/go is not x86-64 (ELF header $hd)"
[ ! -e "$dest/pkg/tool/darwin_amd64" ] && [ ! -e "$dest/pkg/tool/darwin_arm64" ] || tl_die "a darwin toolchain was staged in $dest/pkg/tool"

out="${LINUX_CROSS_OUT:-$WORK/out}"
mkdir -p "$out"
archive="$out/$root-$PKG_VERSION-linux-x86_64.tar.gz"

# spec: PORT.md, the build chain -- the build record, as the lines' package scripts write it; host and root say what this archive is.
sh "$SHIPYARD_SCRIPTS/build-info.sh" "$dest/build-info-linux-cross.txt" \
  variant=linux-cross host=linux-x86_64 root="$root" prefix="$CROSS_PREFIX" \
  go_version="$GO_VERSION" go_line="$GO_LINE" pkg_version="$PKG_VERSION" port_version="$(tr -d '[:space:]' < "$PORT_DIR/UPSTREAM_VERSION")" \
  recaulk_version="$RECAULK_VERSION" ca_sha256="$CA_SHA256" clang22_version="$CLANG22_VERSION" \
  $(sed -n 's/^\([a-z0-9]*\)=\(.*\)$/built_\1=\2/p' "$WORK/cc/versions")
cp "$dest/build-info-linux-cross.txt" "$out/build-info-linux-cross.txt"

# spec: PORT.md, the build chain -- the archive carries its own mavergreen.plist, so install@v1 `products:` takes the manifest from it rather than
#       from the cross pkg (whose requires, clang22-cross and Longboat, are a Mac's). Same identifier, product, name, group, line and
#       version as the cross pkg's; it requires what the Linux wrapper calls: clang22 at its prefix, from the first release that ships
#       dsymutil (Go's darwin link asks for it), and the 10.9 SDK.
gominor="${GO_VERSION%.*}"
sh "$SHIPYARD_SCRIPTS/stage_product.sh" --stage "$pstage" --product "$root" --name "Go $gominor cross toolchain for Mavericks" \
  --group go --line "$GO_LINE-cross" --version "$PKG_VERSION" --exclude bin/mavericks-cross-clang \
  --requires "clang22>=$LINUX_CLANG22_FLOOR" --requires sdk109 --scripts-out "$WORK/linux-cross-scripts" >&2
[ -f "$dest/mavergreen.plist" ] || tl_die "stage_product.sh left no $dest/mavergreen.plist"
rm -rf "$WORK/linux-cross-scripts"
mv "$dest" "$stage/opt/mavergreen/$root"
rm -rf "$pstage"
dest="$stage/opt/mavergreen/$root"

# spec: PORT.md, the build chain -- reproducible: files sorted by name, owner 0:0 (numeric), every mtime SOURCE_DATE_EPOCH, gzip -n.
#       These are GNU tar's options; 10.9's bsdtar has none of them (and writes another format), so a host without GNU tar
#       (gtar, or tar --version saying GNU) stops here, with the staging in place.
sde="$(sh "$SHIPYARD_SCRIPTS/source-date-epoch.sh")" || exit $?
tar_cmd=""
for c in tar gtar; do
  if "$c" --version 2>/dev/null | grep -q 'GNU tar'; then tar_cmd="$c"; break; fi
done
[ -n "$tar_cmd" ] || tl_die "no GNU tar (tar or gtar) on this host, so no reproducible archive; the staging is $dest"
( cd "$stage" && "$tar_cmd" --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$sde" --format=gnu -cf - opt ) | gzip -n -9 > "$archive.tmp"
mv "$archive.tmp" "$archive"
echo "$archive"
