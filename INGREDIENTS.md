# Build ingredients

No upstream release notes: golang-port is its own upstream; its notes are its own.

golang-port bakes in no ingredients. Its version is hand-set in `UPSTREAM_VERSION` and released
when no `v<version>` tag exists, so it declares no release state. That matches the golang lines,
which adopt declared state together or not at all (spec "Out of scope").

## Conformance deviations

- artifact-conformance: golang-port is a build-chain library that publishes a tarball, and the golang lines publish the pkgs it builds (build/package.sh), so this repo's release workflow has no pkg for check-artifact-conformance.sh to read. Exit: shipyard's conventions gate keys on published pkg assets, not on which seam scripts a repo holds; this line goes when the gate does.
- on-target: golang-port is a build-chain library that publishes a tarball, and the golang lines publish the pkgs, so no job here installs a pkg on real 10.9; tests/on-target/run.sh is the suite a line's on-target job runs in the Mavergreen/mavericks-vm guest. Exit: shipyard's conventions gate keys on published pkg assets, not on which seam scripts a repo holds; this line goes when the gate does.
- product-layout:build/provision-linux.sh: on Linux a line's products are laid out by this script, not by their pkgs through install@v1 `products:`, whose install step is macOS's installer; it reproduces each pkg's tree and mavergreen.plist from the release's own assets. Exit: shipyard's queue entry "install@v1 `products:` learns Linux assets", after which the script is deleted.
