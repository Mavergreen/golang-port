#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- build/env.sh: the one place a line's inputs become the build's variables. Sourced, not executed.
#       usage: LINE_ROOT=<line checkout> . "$PORT_DIR/build/env.sh"
#       A line (golang-126, golang-127, ...) holds only its inputs: UPSTREAM_VERSION, components/recaulk/version,
#       components/clang22/version, line.env (CROSS_MIN_OS, CA_SHA256) and optionally VERSION. Everything the
#       build scripts need is derived here, identically on every host.
# spec: PORT.md, the build chain -- a sourced file cannot locate itself in every sh (dash has no BASH_SOURCE), so the caller says where the
#       port is: every port script sets PORT_DIR before it sources this.
[ -n "${PORT_DIR:-}" ] || { echo "env.sh: PORT_DIR is not set -- the caller sets it to the port checkout before sourcing" >&2; exit 2; }
export PORT_DIR
[ -n "${LINE_ROOT:-}" ] || { echo "env.sh: LINE_ROOT is not set -- point it at the line checkout" >&2; exit 2; }
export LINE_ROOT

# spec: PORT.md, the build chain -- $SHIPYARD / $SHIPYARD_SCRIPTS, from the port's own copy of shipyard's template.
. "$PORT_DIR/build/msc.sh"

# spec: PORT.md, the build chain -- a Go MINOR LINE is a product: each line installs side by side with the next, with its own prefix,
#       identifier, updater and feed. GO_LINE is derived from UPSTREAM_VERSION (<x>.<y>.z -> <x><y>), never
#       configured; a caller-supplied $GO_LINE is only a CHECK against the derived value, never an override.
[ -f "$LINE_ROOT/UPSTREAM_VERSION" ] || { echo "env.sh: no UPSTREAM_VERSION in $LINE_ROOT" >&2; exit 1; }
GO_VERSION="$(tr -d '[:space:]' < "$LINE_ROOT/UPSTREAM_VERSION")"
_env_line="$(printf '%s' "$GO_VERSION" | sed -n 's/^\([0-9]*\)\.\([0-9]*\)\..*$/\1\2/p')"
[ -n "$_env_line" ] || { echo "env.sh: cannot derive GO_LINE from $LINE_ROOT/UPSTREAM_VERSION ($GO_VERSION)" >&2; exit 1; }
if [ -n "${GO_LINE:-}" ] && [ "$GO_LINE" != "$_env_line" ]; then
  echo "env.sh: GO_LINE=$GO_LINE was given but $LINE_ROOT/UPSTREAM_VERSION holds Go $GO_VERSION, which derives $_env_line -- line and upstream disagree" >&2
  exit 1
fi
GO_LINE="$_env_line"; unset _env_line
export GO_VERSION GO_LINE

# spec: PORT.md, the build chain -- Package version: <upstream>-mavericks.<rev>. The release workflow writes VERSION; before a release is
#       cut, fall back to the computed auto version so a build never depends on a committed VERSION file.
if [ -f "$LINE_ROOT/VERSION" ]; then
  PKG_VERSION="$(cat "$LINE_ROOT/VERSION")"; _env_vsrc="$LINE_ROOT/VERSION"
else
  PKG_VERSION="$(sh "$LINE_ROOT/build/version.sh" auto | sed -n 's/^FULL=//p')"; _env_vsrc="$LINE_ROOT/build/version.sh auto"
fi
# spec: PORT.md, the build chain -- a package's name and manifest must agree with the Go it holds: a stale VERSION (left from the line's
#       previous Go) refuses here rather than ship a pkg named for one Go and built from another.
[ -n "$PKG_VERSION" ] || { echo "env.sh: no package version from $_env_vsrc (UPSTREAM_VERSION says $GO_VERSION)" >&2; exit 1; }
case "$PKG_VERSION" in
  "$GO_VERSION"-mavericks.*) _env_rev="${PKG_VERSION#"$GO_VERSION"-mavericks.}" ;;
  *) _env_rev="" ;;
esac
case "$_env_rev" in
  ""|*[!0-9]*) echo "env.sh: $_env_vsrc says '$PKG_VERSION', but $LINE_ROOT/UPSTREAM_VERSION says $GO_VERSION: want $GO_VERSION-mavericks.<digits> -- is VERSION stale?" >&2; exit 1 ;;
esac
unset _env_rev _env_vsrc
export PKG_VERSION

# spec: PORT.md, the build chain -- a component's pinned version: one token in components/<name>/version
_env_component() {
  [ -f "$LINE_ROOT/components/$1/version" ] || { echo "env.sh: no $LINE_ROOT/components/$1/version" >&2; exit 1; }
  _env_v="$(tr -d ' \t\r\n' < "$LINE_ROOT/components/$1/version")"
  [ -n "$_env_v" ] || { echo "env.sh: $LINE_ROOT/components/$1/version is empty" >&2; exit 1; }
  printf '%s' "$_env_v"
}
RECAULK_VERSION="$(_env_component recaulk)" || exit $?
CLANG22_VERSION="$(_env_component clang22)" || exit $?
export RECAULK_VERSION CLANG22_VERSION

# spec: PORT.md, the build chain -- the line's own constants, in line.env (plain NAME=value lines)
[ -f "$LINE_ROOT/line.env" ] || { echo "env.sh: no $LINE_ROOT/line.env" >&2; exit 1; }
for _env_k in CROSS_MIN_OS CA_SHA256; do
  _env_v="$(sed -n "s/^$_env_k=//p" "$LINE_ROOT/line.env" | sed -n 1p)"
  [ -n "$_env_v" ] || { echo "env.sh: $_env_k is not set in $LINE_ROOT/line.env" >&2; exit 1; }
  eval "$_env_k=\$_env_v"
done
unset _env_k _env_v
export CROSS_MIN_OS CA_SHA256

# spec: PORT.md, the build chain -- a family checkout may live on NFS, where a build cost 11.16s wall / 25% CPU against 2.96s / 88% on local
#       disk, with identical user time -- the whole difference is I/O wait.
: "${MAVERICKS_BUILD_ROOT:=${TMPDIR:-/tmp}/mm-build}"
export MAVERICKS_BUILD_ROOT
# spec: PORT.md, the build chain -- MAVERICKS_WORK still wins when set (a private work dir never clobbers edits); MAVERICKS_BUILD_ROOT="$PWD"
#       is the deliberate in-tree escape hatch.
export WORK="${MAVERICKS_WORK:-$MAVERICKS_BUILD_ROOT/golang-go$GO_LINE}"

export PREFIX="/usr/local/mavergreen/go${GO_LINE}"
export MACOS_MIN="10.9"
# spec: PORT.md, the build chain -- Both products bake the SAME CA convention path into the std trust model: the NATIVE prefix's bundle
#       dir. Native populates it; cross-built apps look there.
export CROSS_PREFIX="/usr/local/mavergreen/go${GO_LINE}-cross"
export CA_DIR="$PREFIX/etc/openssl"   # @SSLDIR@ substitution target (native == cross)
export WLU_SYMS="_xpc_date_create_from_current"
# spec: PORT.md, the build chain -- CA bundle: curl.se cacert.pem; its SHA-256 is the line's, in line.env.
export CA_URL="https://curl.se/ca/cacert.pem"
