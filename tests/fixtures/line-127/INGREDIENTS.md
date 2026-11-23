# Build ingredients (fixture)

A copy of the deviation every Go line declares; tests/package-test.sh packages this line.

## Conformance deviations

- standalone-text:src/crypto/x509/root_keychainunion_darwin*.go: Go's darwin CA-bundle default list names where built programs find the family's trust store (PORT.md invariant 7); the toolchain never reads it
