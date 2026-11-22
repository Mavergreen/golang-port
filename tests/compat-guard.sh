#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- shipyard's assert_binary_compatible.sh reads Mach-O load commands (clang22's llvm-otool on a Linux
#       host, otool on a Mac), so the guard runs wherever the binaries do. Called with no binaries (as run-repo-tests does, before anything
#       is built) there is nothing to guard yet: exit 77 = SKIP, the family convention. The real gate is the explicit invocation on the
#       shipped binaries: sh tests/compat-guard.sh <binary>...
set -eu
[ "$#" -gt 0 ] || { echo "no binaries given (nothing built yet) -- skipping"; exit 77; }
: "${SHIPYARD_SCRIPTS:?mavericks-shipyard not found; install it -- see its README}"
# spec: PORT.md, the build chain -- the Mach-O readers are clang22's llvm-lipo, llvm-otool, llvm-nm and llvm-strings on every host (a Linux
#       host has no lipo or otool, and its nm is not a Mach-O reader); shipyard reads them from LIPO, OTOOL, NM and STRINGS.
clang22="${MAVERGREEN_CLANG22:-/usr/local/mavergreen/clang22}"
[ -x "$clang22/bin/llvm-lipo" ] && : "${LIPO:=$clang22/bin/llvm-lipo}"
[ -x "$clang22/bin/llvm-otool" ] && : "${OTOOL:=$clang22/bin/llvm-otool}"
[ -x "$clang22/bin/llvm-nm" ] && : "${NM:=$clang22/bin/llvm-nm}"
[ -x "$clang22/bin/llvm-strings" ] && : "${STRINGS:=$clang22/bin/llvm-strings}"
export LIPO OTOOL NM STRINGS
# spec: PORT.md, the build chain -- off macOS there is no otool or nm that reads Mach-O, so without clang22 say so rather than fall back to the host's.
if [ "$(uname -s)" != Darwin ] && [ ! -x "$clang22/bin/llvm-otool" ]; then
  echo "compat-guard: no clang22 at $clang22 and this host is not macOS, so there is no Mach-O reader -- install clang22 (install@v1 products: clang22) or set MAVERGREEN_CLANG22" >&2
  exit 1
fi
MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_clock_gettime' sh "$SHIPYARD_SCRIPTS/assert_binary_compatible.sh" "$@"
