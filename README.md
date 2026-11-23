# golang-port

**What:** the trust overlay that makes Go on Mac OS X 10.9 trust the right certificates, and the
build chain (`build/`) that turns a line's inputs into its toolchains, pkgs and Linux cross archive
on Linux, a modern Mac or 10.9. Every Mavergreen Go line (`golang-126`, `golang-127`, …) uses both.

**Why it's here:** so the lines don't each carry their own copy.

**Change it:** edit, then try it in a line without releasing:

    LINE_ROOT=../mavergreen-golang-127 sh build/build-builder.sh
    LINE_ROOT=../mavergreen-golang-127 sh tests/trust-static.sh

then, in the 10.9 guest with the line's pkg installed, `GO_LINE=127 sh tests/on-target/run.sh`.

**Release it:** bump `UPSTREAM_VERSION`, push `main`. If the lines' patches must change too, it's a major bump.

**Details:** `PORT.md`.
