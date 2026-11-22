# golang-port

**What:** the trust overlay that makes Go on Mac OS X 10.9 trust the right certificates.
Every Mavergreen Go line (`golang-126`, `golang-127`, …) applies it.

**Why it's here:** so the lines don't each carry their own copy.

**Change it:** edit, then try it in a line without releasing:

    GOLANG_PORT_DIR=../mavergreen-golang-port sh tests/trust/unit-trust.sh

**Release it:** bump `UPSTREAM_VERSION`, push `main`. If the lines' patches must change too, it's a major bump.

**Details:** `PORT.md`.
