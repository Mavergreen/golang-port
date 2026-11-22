# Build ingredients

No upstream release notes: golang-port is its own upstream; its notes are its own.

golang-port bakes in no ingredients. Its version is hand-set in `UPSTREAM_VERSION` and released
when no `v<version>` tag exists, so it declares no release state. That matches the golang lines,
which adopt declared state together or not at all (spec "Out of scope").

## Conformance deviations

- artifact-conformance: build/package.sh builds the native and cross pkgs, but the release workflow does not yet pipe artifact-facts.sh into check-artifact-conformance.sh. Exit: the phase-3 release workflow does, and this line goes.
- on-target: no release.yml job installs the port's pkgs on real 10.9 yet, because the port's own release publishes a tarball today and the pkgs are built by the lines. Exit: the phase-3 release workflow installs each pkg in the Mavergreen/mavericks-vm guest and adds that job to publish's needs; this line goes.
