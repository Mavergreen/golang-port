# Build ingredients

No upstream release notes: golang-port is its own upstream; its notes are its own.

golang-port bakes in no ingredients. Its version is hand-set in `UPSTREAM_VERSION` and released
when no `v<version>` tag exists, so it declares no release state. That matches the golang lines,
which adopt declared state together or not at all (spec "Out of scope").

## Conformance deviations

- artifact-conformance: golang-port is a build-chain library that publishes a tarball, and the golang lines publish the pkgs it builds (build/package.sh), so this repo's release workflow has no pkg for check-artifact-conformance.sh to read. Exit: shipyard's conventions gate keys on published pkg assets, not on which seam scripts a repo holds; this line goes when the gate does.
- on-target: golang-port is a build-chain library that publishes a tarball, and the golang lines publish the pkgs, so no job here installs a pkg on real 10.9; tests/on-target/run.sh is the suite a line's on-target job runs in the Mavergreen/mavericks-vm guest. Exit: shipyard's conventions gate keys on published pkg assets, not on which seam scripts a repo holds; this line goes when the gate does.
