#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/apply-patches.sh: applies the line's hook patches ($LINE_ROOT/patches/*.patch), then the
#       port's own patches ($PORT_DIR/patches/*.patch, line-independent, numbered after the lines'), then the port's overlay
#       (apply-overlay.sh, @SSLDIR@ -> $CA_DIR), to the pristine tree at $WORK/go.
#       usage: LINE_ROOT=<line checkout> sh build/apply-patches.sh
set -eu
PORT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PORT_DIR
. "$PORT_DIR/build/env.sh" || exit $?

pdir="$LINE_ROOT/patches"
ls "$pdir"/*.patch >/dev/null 2>&1 || { echo "apply-patches.sh: no patches in $pdir" >&2; exit 1; }
# spec: PORT.md, port patch 0020 -- the port's own patches are not optional: the products' go.env names CC relative to GOROOT
ls "$PORT_DIR"/patches/*.patch >/dev/null 2>&1 || { echo "apply-patches.sh: no patches in $PORT_DIR/patches" >&2; exit 1; }
[ -f "$WORK/go/src/make.bash" ] || { echo "apply-patches.sh: no Go tree at $WORK/go; run build/fetch-go.sh first" >&2; exit 1; }

# spec: PORT.md, the build chain -- shipyard's apply_patches.sh (-p1, -F 0) is not used: the hook patches are traditional -p0
#       patches with .orig headers, so with -p1 the very first one (0001-make-bash-bootstrap-ldflags.patch) finds no file to
#       patch on both Go 1.26.11 and 1.27.4. -F 3 allows the context to have drifted by a few lines, the ordinary case for
#       a new Go minor. Fuzz decides only whether a patch APPLIES, never whether the result is CORRECT: the gates
#       (tests/trust, the compat guard, the distrust acceptance test) are what judge that. -V none and --no-backup-if-mismatch leave
#       no .orig or .~N~ files (the latter is what BSD patch 2.5.8 on 10.9 writes when a hunk applies with fuzz).
cd "$WORK/go"
for p in "$pdir"/*.patch "$PORT_DIR"/patches/*.patch; do
  echo "applying $(basename "$p")"
  patch -p0 -F 3 -V none --no-backup-if-mismatch < "$p" || { echo "apply-patches.sh: $(basename "$p") does not apply to $WORK/go" >&2; exit 1; }
done

sh "$PORT_DIR/apply-overlay.sh" "$WORK/go" "$CA_DIR"
echo "hook patches from $pdir + the port's patches + overlay applied (@SSLDIR@ -> $CA_DIR)"
