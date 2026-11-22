#!/bin/sh
# platform: host-agnostic
# spec: PORT.md, the build chain -- the build is Rosetta-free: a native darwin/amd64 toolchain is built by the host's own builder, never by
#       running amd64 code under Rosetta. Matches CODE only: comments are stripped first, so a comment describing the antipattern is fine.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/.."
fail=0
say() { echo "GUARD: $1"; }
code() { sed 's/#.*//' "$1"; }

for f in "$root"/build/*.sh; do
  if code "$f" | grep -Eq 'GOHOSTARCH=amd64'; then
    say "FAIL: ${f##*/} sets GOHOSTARCH=amd64 (would run amd64 under Rosetta)"; fail=1
  fi
  if code "$f" | grep -Eq 'arch[[:space:]]+-(-?)(arch[[:space:]]+)?x86_64'; then
    say "FAIL: ${f##*/} invokes \`arch ... x86_64\` (amd64 execution)"; fail=1
  fi
done
grep -q 'make.bash' "$root/build/build-builder.sh" || { say "FAIL: no make.bash in build-builder.sh"; fail=1; }

# spec: PORT.md, the build chain -- the release workflow must not gate the build on Rosetta: any Rosetta install is best-effort (|| true)
wf="$root/.github/workflows/release.yml"
if [ -f "$wf" ] && grep -Eq 'install-rosetta' "$wf"; then
  grep -Eq 'install-rosetta[^|]*\|\|[[:space:]]*true' "$wf" || {
    say "FAIL: release.yml installs Rosetta without '|| true' (build would depend on it)"; fail=1; }
fi

[ "$fail" -eq 0 ] && say "OK: the build path is Rosetta-free" || exit 1
