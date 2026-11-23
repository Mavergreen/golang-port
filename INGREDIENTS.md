# Build ingredients

No upstream release notes: golang-port is its own upstream; its notes are its own.

golang-port bakes in no ingredients. Its version is hand-set in `UPSTREAM_VERSION` and released
when no `v<version>` tag exists, so it declares no release state. That matches the golang lines,
which adopt declared state together or not at all (spec "Out of scope").

## Conformance deviations

- pkg-builder-library: holds the Go lines' pkg builder; its own release publishes only the port tarball
