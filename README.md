**This README has not been read or edited by a human yet.** Until it has, this project cannot cut its first release.

# golang-port

The keychain-union trust overlay for Go on Mac OS X 10.9 (Mavericks): the files that make
`crypto/x509` on darwin read the system roots from all three keychain trust domains, union them
with a CA bundle, and subtract distrust. It also holds `apply-overlay.sh`, which copies the overlay
into a Go source tree, and `PORT.md`, which explains every change the Mavergreen Go lines carry.

It is consumed by the Mavergreen Go toolchain lines (`golang-126`, `golang-127`, and later minors).
Each line pins a released `golang-port-<version>.tar.gz`, verifies it against the release's
`SHA256SUMS`, and applies it to the Go source before its own small hook patches.

## Local development

To try an overlay change against a line without releasing it, point the line's checkout at this one:

    GOLANG_PORT_DIR=../mavergreen-golang-port sh tests/trust/unit-trust.sh

`GOLANG_PORT_DIR` replaces the pinned tarball and the build says loudly that it is unpinned. A
release build refuses it.

## Releasing

The version is `UPSTREAM_VERSION`, set by hand. A push to `main` releases it when no `v<version>`
tag exists yet. A change that requires the lines' hook patches to change is a major bump.

## License

The overlay derives from Go's own source; see `LICENSE`.
