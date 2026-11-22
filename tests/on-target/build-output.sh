#!/bin/sh
# platform: host-agnostic -- sourced by tests/on-target/run.sh in the 10.9 guest, and by tests/on-target-output-test.sh on any host
# spec: PORT.md, the build chain -- on-target builds print no linker warning. A link that says an object "is newer than target
#       minimum", or any other `ld64.lld: warning:`, fails its check, naming the line: a line's toolchain links clean on 10.9.
#       usage: . tests/on-target/build-output.sh   (the caller defines bad and sets GO_LINE)
#              ot_check_output <label> <output>     fails <label> through bad when <output> holds a linker warning
#              ot_build <label> <dir> <command...>  runs <command> in <dir>, stderr with stdout, prints its output, checks it,
#                                                   and returns the command's status

ot_check_output() {
  _ot_w="$(printf '%s\n' "$2" | grep -E 'newer than target minimum|ld64\.lld: warning:' || true)"
  [ -z "$_ot_w" ] || bad "go$GO_LINE $1: the build printed a linker warning, and a line's toolchain links clean: $_ot_w"
}

ot_build() {
  _ot_label=$1; _ot_dir=$2; shift 2
  _ot_rc=0
  _ot_out="$(cd "$_ot_dir" && "$@" 2>&1)" || _ot_rc=$?
  [ -z "$_ot_out" ] || printf '%s\n' "$_ot_out"
  ot_check_output "$_ot_label" "$_ot_out"
  return "$_ot_rc"
}
