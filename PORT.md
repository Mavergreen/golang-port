# PORT.md — what this port carries, and why

Go upstream does not support Mac OS X 10.9. This port carries changes to make it build and run
there. **This file is the authority for why each one exists.** Design specs are history; if a spec
and this file disagree, this file wins, and the change to it goes in the same commit as the code.

This file serves every Mavergreen golang line, not one: the overlay files and the port's own patches
(`patches/`) live here, and the hook patches each line repo still carries are explained here too. A line's `tests/port-md-test.sh` holds
that line's patches to this file (a hook patch with no section, or a line patch that re-adds an
overlay file, fails the line's build). This port's own `tests/port-md-test.sh` holds this file to
the overlay and to `patches/`.

Before changing or dropping any carried change during a port to a new Go minor: read its entry.
"Upstream changed this area" is a reason to re-read, never a reason to drop.

## Trust invariants (crypto/x509 on darwin)

These hold on every line. Tests named `TestKeychainUnion*` pin them; `tests/on-target/run.sh` (in the
10.9 guest) requires those tests to run and pass, and `tests/trust-static.sh` (on the lines' Linux build) runs the build-tag-free
ones and checks the patched source. These change only through a trust-policy brainstorm, never
inside a port.

1. **The system roots are the keychain union:** anchors from all three trust domains (user, admin,
   system; Keychain Access semantics, Go 1.16/1.17's code) ∪ certificates from **every existing
   bundle file**, minus every keychain-distrusted certificate. Every bundle contributes — this is
   not a search order. *Why:* one Go verifier over a union of anchors, with distrust as a veto, is
   the model the pkgsrc umbrella chose over Apple's 2013 engine (spec 2026-09-13 §3.2).
   *Reconsider:* removing stale roots (10.9 still trusts roots Mozilla has removed) is a separate
   trust-policy brainstorm, deliberately deferred (specs 2026-09-13 §6, 2026-09-16). Never a side
   effect of a port. Go's verifier does no AIA fetching: a server that omits its intermediate
   certificates fails verification, as with Go on Linux. `GODEBUG=x509usefallbackroots=0` selects
   Apple's verifier, which fetches them. This predates go127 (go126 behaves the same).
2. **A keychain Deny always vetoes** — any built chain containing a distrusted certificate is
   rejected, including a distrusted intermediate the server supplies (patch 0010).
3. **`SSL_CERT_FILE` / `SSL_CERT_DIR` shape the union, never replace it.** `SSL_CERT_FILE` replaces
   the default bundle-file list; `SSL_CERT_DIR` (colon-separated) adds each directory's files; the
   keychain stays in and the veto still applies. *Why:* a user's Never Trust must not silently stop
   applying because a Python/conda environment or a shell rc set `SSL_CERT_FILE` (spec 2026-07-19).
   **Upstream Go 1.27 differs:** it makes these variables exclusive on darwin (on-disk roots only).
   We keep our semantics and say so in release notes. Upstream's `SystemCertPool` doc comment
   (cert_pool.go), which says SSL_CERT_* disables the platform verifier unless
   `x509sslcertoverrideplatform=0`, does not describe darwin in this toolchain.
4. **`GODEBUG=x509sslcertoverrideplatform` has no effect on darwin.** Upstream's `=0` means
   "pre-1.27 behaviour"; ours is invariant 3. It matters: the setting is registered
   `Changed: 27, Old: "0"`, so every program whose go.mod says `go 1.26` or lower gets `=0` by
   default.
5. **`GODEBUG=x509usefallbackroots=0` selects Apple's verifier** (the `systemPool` marker), on every
   macOS version; `=1` with `SetFallbackRoots` uses the program's fallback pool, as upstream does —
   but the keychain-distrust veto still applies, because `initSystemRoots` builds the union first
   (as in go126) before ever swapping in the fallback pool; a program's own `SetFallbackRoots` never
   panics and never displaces the union unless `=1`.
6. **An empty union is an error**, so `Verify` with nil Roots falls back to Apple's verifier and
   `SystemCertPool` reports it.
7. **Default bundle files:** `/usr/local/mavergreen/ca-certs/etc/openssl/certs/ca-certificates.crt`
   (the family's line-independent bundle — a contract the ca-certs product must honour), this line's
   own `@SSLDIR@/certs/ca-certificates.crt`, then `/usr/local/etc/openssl/cert.pem`,
   `/etc/openssl/certs/ca-certificates.crt`, `/etc/ssl/certs/ca-certificates.crt`, `/etc/ssl/cert.pem`.
   Every default path is a trust input: `/usr/local/mavergreen` (and so the ca-certs tree) must be
   root-owned, as must `/usr/local/etc/openssl`. *Reconsider* when the ca-certs product ships: the
   lines may then stop carrying their own bundle copy.

## Hook ↔ overlay interface

Overlay = files this port adds whole (line-independent). Hooks = edits to upstream files (per-minor;
Go churns them, and each line carries its own). A renamed function breaks the hook at compile time,
which goes red on the line. So **renaming or removing an identifier in the second column is a major
bump** of this port.

| Hook patch (upstream file) | Uses from the overlay |
|---|---|
| 0010-verify-distrust-veto.patch (`verify.go`) | `keychainUnionDistrusted`, `keychainUnionFilterDistrusted` |
| 0013-root-darwin-loadsystemroots-legacy-sectrust.patch (Go 1.26: `root_darwin.go`, `systemVerify` and `loadSystemRoots`) | `keychainUnionNativeVerifier`, `keychainUnionLoadSystemRoots`, `keychainUnionLegacySecTrust`, `keychainUnionLegacyEvaluate` |
| 0013-root-darwin-legacy-sectrust.patch (Go 1.27 and later: `root_darwin.go`, `systemVerify`) | `keychainUnionLegacySecTrust`, `keychainUnionLegacyEvaluate` |
| 0016-root-loadsystemroots-keychainunion-hook.patch (Go 1.27 and later: `root.go`, `loadSystemRoots`) | `keychainUnionPlatformRoots` (darwin: `root_keychainunion_darwin.go`; `!darwin`: `root_keychainunion_other.go`) |
| 0018-root-test-darwin-keychainunion.patch (Go 1.27 and later: `root_test.go`, `verify_test.go`, `hybrid_pool_test.go`) | — (points readers at `TestKeychainUnion*`) |

| Overlay file (new file) | Uses from hooks |
|---|---|
| `root_keychainunion_darwin.go` | 0005/0006's `internal/macos` SecTrustSettings wrappers |

**Upstream internals the overlay relies on**

These are what break the overlay across Go minors — none of them are part of the hook/overlay
interface above, but the overlay reaches into upstream's own unexported state to do its job:

- `root_keychainunion_darwin.go` uses `x509usefallbackroots` and `CertPool.systemPool`.
- The darwin tests (`root_keychainunion_darwin_test.go`) use `once`, `systemRootsMu`, `systemRoots`, `systemRootsErr`, `fallbacksSet` and
  `useFallbackRoots`.
- 0016 (Go 1.27 and later) relies on `loadSystemRoots` living in root.go.

## Carried changes
### 0001-make-bash-bootstrap-ldflags.patch
Hook. Injects the legacy-support link flags into cmd/dist's bootstrap build, from
`GO_BOOTSTRAP_LDFLAGS`; inert when unset. *Why:* the bootstrap toolchain must link the 10.9 shim.
*Reconsider:* if the build stops building a bootstrap that runs on 10.9.

### 0002-cmd-dist-buildtool-bootstrap-ldflags.patch
Hook. The same flags for the bootstrap-tools build; inert when unset. *Why/Reconsider:* as 0001.

### 0003-runtime-osinit-hack-version-guard.patch
Hook. Runs the osinit_hack fork+exec-hang workaround only on macOS ≥ 10.12, where
`notify_is_valid_token` exists. *Why:* on 10.9–10.11 the symbol is absent and binding it kills the
binary. *Reconsider:* never while 10.9 is a target.

### 0004-runtime-cgo-no-unknown-pragmas.patch
Hook. Appends `-Wno-unknown-pragmas` to runtime/cgo's flags. *Why:* 10.9's system clang (6.0) warns
on newer pragmas and runtime/cgo builds with `-Werror`, so on-box cgo builds fail. Diagnostic-only.
*Reconsider:* if runtime/cgo drops `-Werror` or its pragmas.

### 0005-macos-sectrustsettings-wrappers.patch
Hook. Restores the SecTrustSettings wrappers upstream removed in 1.26 (Go 1.24/1.18 code), plus the
older-macOS SecTrust calls and `SecTrustGetCssmResultCode`. *Why:* the union reads trust settings the
way Go 1.16/1.17 did (invariant 1); Apple's verifier below 10.15 needs the older calls.
*Reconsider:* never while invariant 1 holds.

### 0006-macos-sectrustsettings-trampolines.patch
Hook. The assembly trampolines for 0005's wrappers. *Why/Reconsider:* as 0005.

### 0010-verify-distrust-veto.patch
Hook. Drops any built chain containing a keychain-distrusted certificate. *Why:* invariant 2 —
anchor exclusion alone cannot reject a distrusted intermediate that also chains to a trusted root.
*Reconsider:* never while invariant 2 holds.

### 0011-cmd-dist-extlink-darwin-amd64.patch
Hook. Lets `GO_EXTLINK_ENABLED=darwin/amd64` be baked in at make.bash time. *Why/Reconsider:* 0012.

### 0012-cmd-link-extlink-darwin-amd64.patch
Hook. `GO_EXTLINK_ENABLED=darwin/amd64`: external-link every darwin/amd64 binary, keep the automatic
choice elsewhere. *Why:* Go internal-links cgo-free binaries, which never run the CC wrapper, so on
10.9 they lack the legacy shim, carry a modern minimum-OS stamp (12.0 in 1.26, 13.0 in 1.27) and die
with `_clock_gettime` unresolved. `tests/pure-go-link.sh` is the gate. *Reconsider:* never while
10.9 is a target.

### 0013-root-darwin-loadsystemroots-legacy-sectrust.patch
Hook (Go 1.26). Does what 0013-root-darwin-legacy-sectrust.patch does for `systemVerify` (below),
and also carries darwin's `loadSystemRoots` in `root_darwin.go`, because Go 1.26 keeps it there: it
returns upstream's `systemPool` marker when `keychainUnionNativeVerifier()` says
`GODEBUG=x509usefallbackroots=0` selected Apple's verifier, and otherwise serves the keychain union
from `keychainUnionLoadSystemRoots()`. *Why:* invariants 1, 5, 6 — the union is the system root
store, a program's own `SetFallbackRoots` behaves as upstream instead of panicking, an empty union
is an error, and Apple's verifier must work on every macOS. *Reconsider:* never while invariants 1,
5 and 6 hold; the `loadSystemRoots` half goes away if Go 1.26 ever moves it to `root.go`, as
Go 1.27 did (then 0016 is the hook).

### 0013-root-darwin-legacy-sectrust.patch
Hook. Makes upstream's `systemVerify` work on 10.9: the SSL policy is passed as a single
`SecPolicyRef` (10.9's SecTrustEvaluate faults on a policies CFArray built by
`CFArrayCreateMutable`), and below 10.15 evaluation and chain extraction use `SecTrustEvaluate` /
`SecTrustGetCertificateAtIndex`. *Why:* invariant 5 — Apple's verifier must work on every macOS.
*Reconsider:* never while invariant 5 holds.

### 0016-root-loadsystemroots-keychainunion-hook.patch
Hook (Go 1.27 and later). One statement at the top of `root.go`'s `loadSystemRoots` hands darwin to
`keychainUnionPlatformRoots`. *Why:* Go 1.27 moved darwin's `loadSystemRoots` there from
`root_darwin.go`. Keep it one statement so it survives future moves. *Reconsider:* only if upstream
moves `loadSystemRoots` again.

### 0018-root-test-darwin-keychainunion.patch
Hook (tests; Go 1.27 and later). Upstream tests that assert upstream's darwin semantics skip on darwin: `TestEnvVars`
and `TestLoadSystemCertsLoadColonSeparatedDirs` (env-exclusive roots, which we deliberately lack —
invariant 3), and `TestIssue51759` (verify_test.go) and `TestHybridPool` (hybrid_pool_test.go), which
assume Apple's verifier is the default (Apple's error strings; AIA-fetched intermediates —
invariants 1, 5). `TestSSLCertEnvOverride` keeps running and asserts invariant 4 on darwin.
`tests/on-target/run.sh` requires all four skips, each with its exact reason, and `TestSSLCertEnvOverride` passing
(`tests/on-target-trust-test.sh` proves the check). *Reconsider:* when upstream's tests stop
asserting upstream's darwin semantics.

### 0020-cmd-go-goroot-relative-cc.patch
Port patch (line-independent, in this port's `patches/`; `build/apply-patches.sh` applies it after the line's hook patches, and
it applies unchanged to Go 1.26 and 1.27). `cmd/go/internal/cfg`'s `readEnvFile`, for a value read from `$GOROOT/go.env`, passes
CC and CXX through `gorootRelativeCC`: a command that is relative and has a separator (`bin/mavericks-clang`) is joined to
GOROOT, and quoted if the result holds a space, as Go quotes any CC. Values from the environment or the user's `go env -w` file,
absolute paths and bare names (a PATH lookup) are untouched. The three build scripts write `CC=bin/mavericks-clang` or
`CC=bin/mavericks-cross-clang`, so `go env CC` prints the toolchain's own wrapper wherever the toolchain is: for an installed
pkg, the same absolute path as before. *Why:* Go does not expand go.env values, so with an absolute prefix in go.env a
toolchain copied or unpacked anywhere else execs a path that does not exist, and every darwin link is external; a standalone
archive must work wherever it is unpacked. *Upstreamable:* `go env -w` already refuses this shape as relative, so no existing
go.env can mean anything else by it (queued: upstream GOROOT-relative CC in go.env). *Reconsider:* when a Go release carries it,
or the toolchains stop naming their own wrapper in go.env.

### overlay/src/crypto/x509/root_keychainunion.go
Overlay (portable). `buildKeychainUnionPool`, the bundle parsing and `keychainUnionResolveBundlePaths`
(invariants 1, 3), and the distrust set. *Why:* invariants 1–3. *Reconsider:* never while
invariants 1–3 hold.

### overlay/src/crypto/x509/root_keychainunion_darwin.go
Overlay (darwin). Keychain enumeration (Go 1.16/1.17, with the user→admin fall-through fix),
`keychainUnionLoadSystemRoots`, `keychainUnionPlatformRoots`, Apple's-verifier plumbing for
< 10.15, and the default bundle list. *Why:* invariants 1–7. *Reconsider:* never while
invariants 1–7 hold.

### overlay/src/crypto/x509/root_keychainunion_other.go
Overlay (`!darwin`). `keychainUnionPlatformRoots` returns `handled=false`, so 0016 is inert off
darwin. *Why:* without it `crypto/x509` does not compile for other GOOS (Review: cross-compiling
from a Mac to linux must keep working). *Reconsider:* never while 0016 exists.

### overlay/src/crypto/x509/root_keychainunion_test.go
Overlay (portable tests). Pins invariants 1–3 and the anchor rules (TrustRoot only self-signed,
TrustAsRoot only non-self-signed, Unspecified/Invalid anchor nothing), including
`TestKeychainUnionAllBundlesContribute`. *Reconsider:* never while invariants 1–3 hold.

### overlay/src/crypto/x509/root_keychainunion_darwin_test.go
Overlay (darwin tests). Pins invariants 3–6 on darwin: the loadSystemRoots table, `SetFallbackRoots`
behaviour, Apple's verifier on legacy SecTrust, and the ca-certs path (invariant 7). *Reconsider:*
never while invariants 3–6 hold.

### overlay/src/crypto/x509/testdata/keychainunion-isrgrootx1-chain.pem
Overlay (testdata). The ISRG Root X1 chain the darwin tests verify against. *Reconsider:* as
`root_keychainunion_darwin_test.go`.

## Build chain

The port holds the build chain the golang lines share: a line (golang-126, golang-127, ...) supplies only its inputs, and
`build/` turns them into a toolchain, the same way on every host (a Mac, the 10.9 box, Linux CI). Each entry below is a rule
the chain keeps because Go would otherwise bake the build host into the result. Rules are checked by `tests/`; a change to one
goes in the same commit as its entry.

### -trimpath on every toolchain binary
Build rule. `build-native.sh` installs `cmd` with `go install -a -trimpath -ldflags=-linkmode=external`, and
`build-cross.sh` and `build-linux-cross.sh` with `-trimpath`, so no binary carries the build host's checkout or cache paths. *Why:* without it two hosts
building the same inputs produce different bytes, and Linux CI could not be a byte reference for the 10.9 box.
`-linkmode=external` is the other half: Go internal-links pure-Go darwin binaries and stamps its own minimum-OS floor, so
every binary must go through the C wrapper to get minos 10.9 and Recaulk. *Invariant:* the tree built on Linux and the tree
built on 10.9 differ in no file (`tests/cross-host-bytes.sh`, shipyard's build-equivalence). *Reconsider:* if Go makes the
paths it embeds reproducible without the flag, or `tests/cross-host-bytes.sh` stops being the gate.

### Fixed C-toolchain paths
Build rule. Go hashes the C compiler's absolute path into build IDs, so every host reaches the compiler, the SDK and Recaulk
at the family's installed prefixes: `/usr/local/mavergreen/clang22`, `/usr/local/mavergreen/sdk109/SDKs/MacOSX10.9.sdk`,
`/usr/local/mavergreen/recaulk`, and the products' own `/usr/local/mavergreen/go1NN` and `go1NN-cross`. These are build-time paths
only: what ships does not depend on its own prefix. Each shipped wrapper (`build/write-wrappers.sh`) finds Recaulk in `../lib`
beside itself, from `$0` by expansion (with `CDPATH` emptied), and its clang22 and 10.9 SDK at the family prefix unless `MAVERGREEN_CLANG22`
(`MAVERGREEN_CLANG22_CROSS` for the cross wrapper, whose compiler is another product), or `MAVERGREEN_SDK109` (an sdk109
directory, the one holding `SDKs/MacOSX10.9.sdk`), names another; go.env names the wrapper relative to GOROOT (patch 0020).
`tests/relocate-test.sh` moves the wrappers to a path with a space.
The lookup is relative to the path the wrapper was called by, never resolved: a symlinked wrapper looks for `../lib` beside the link. On Linux,
install@v1 `products:` puts each at its pkg's prefix, as it does on a Mac. `build/c-toolchain.sh` checks each against the line's pin
(`components/<name>/version`) and writes the build wrapper `$WORK/cc/bin/clang`; nothing falls back to a cache path.
The wrapper may sit anywhere because Go reaches it by the bare name `clang` on `PATH`, but `build/env.sh` spells `$WORK` clean (one
slash between parts, no `./`, no trailing slash; relative or `..` refuses), since an unclean GOROOT leaves the work path in
`runtime/cgo` and so changes every darwin/amd64 build ID (`tests/work-path-test.sh`).
*Why:* a path that differs per host changes build IDs, hence bytes. *Invariant:* the paths are derived from the line
(`/usr/local/mavergreen/go${GO_LINE}`), never spelled per line (`tests/prefix-check.sh`); the build is Rosetta-free
(`tests/rosetta-free-guard.sh`); the cross toolchain ships no SDK fetcher (`tests/no-sdk-fetcher-test.sh`). *Reconsider:* if
Go stops hashing compiler paths, or the family moves its prefix.

### CC and CC_FOR_TARGET are unset during make.bash
Build rule. `build-builder.sh` unsets `CC`, `CXX`, `CC_FOR_TARGET`, `CXX_FOR_TARGET`, the target and `CGO_*` before make.bash,
and `tl_go_env` does the same before every `go install`; each variable it found set is named on stderr. The wrapper is found
on `PATH` as `clang`, the same name on every host. *Why:* make.bash bakes `CC` into `zdefaultcc.go`, so a caller's compiler
(Apple's clang on a Mac, gcc on Linux) would become the toolchain's default C compiler. *Invariant:* `go env CC` of a shipped
toolchain is its own wrapper. *Reconsider:* if Go stops baking `CC` from the environment.

### DWARF is kept: dsymutil and strip come from clang22
Build rule. The darwin link runs `dsymutil` and `strip` (and `ar` for a c-archive) by asking the C compiler
`--print-prog-name`. The wrappers answer those three from the clang22 prefix (`dsymutil`, `llvm-strip`, `llvm-ar`), never
from the host's `PATH`; `c-toolchain.sh` refuses a clang22 without them. *Why:* the host's strip differs per host (Apple's on a
Mac, GNU's on Linux, none on a minimal image), and a stripped binary loses the DWARF the shipped toolchain keeps for
debugging. *Invariant:* every linked toolchain binary has a `__DWARF` segment and is byte-identical across hosts; `-a` relinks
them all every build, because `dsymutil` and `strip` are not in Go's action IDs. *Reconsider:* when clang22 stops shipping the
three tools, or the family decides the toolchain ships without DWARF.

### Standing rules and known differences
Rules the chain keeps and differences a reader will notice; none is a regression.

- **Pins.** `build/c-toolchain.sh` is strict (version drift refuses) when `CI=true` or `MAVERGREEN_STRICT_PINS=1`, and lenient on
  a dev box (drift warns once per product and the build goes on; `MAVERGREEN_STRICT_PINS=0` forces lenient even in CI). A missing
  product always refuses. The versions actually used are recorded in build-info, so a lenient build says what it was built with.
- **Apple Silicon is interface-equal, not byte-equal.** An Apple Silicon Mac builds with `clang22-cross`, at another prefix,
  because `clang22`'s pkg is x86_64-only; the compiler path is hashed into build IDs (rule above), so those bytes differ. Linux
  CI and the 10.9 box are the byte references. Exit: a `clang22` alias on Macs; revisit if anyone needs to byte-reproduce a
  release on Apple Silicon.
- **The builder key leaves out the bootstrap on purpose.** `$WORK/builder.key` covers the Go version, the patches, the overlay, the
  clang22 version and `uname -sm`, not the bootstrap Go: make.bash rebuilds the toolchain in three stages, so its output does
  not depend on the bootstrap. Do not add it back.
  sdk109 and Recaulk versions are left out too, deliberately: nothing make.bash builds ships as-is (native relinks with `-a`; cross
  and linux are `CGO_ENABLED=0`), so nobody should add them "for safety".
- **The builder's `bin/` is overwritten by the product build:** `build-native.sh` on a darwin host, `build-linux-cross.sh` on a
  Linux host, install the product's binaries over it (same Go version, so later builds are unaffected).
- **The Linux archive** (`go1NN-cross-<version>-linux-x86_64.tar.gz`) is laid out for install@v1 `products:`: every entry is under
  `opt/mavergreen/go1NN-cross/` (shipyard's `product-tar.py` refuses anything else), and it carries its own
  `opt/mavergreen/go1NN-cross/mavergreen.plist`, rendered by shipyard's `stage_product.sh` with the cross pkg's identifier,
  product, name, line and version but Linux requires: `clang22>=22.1.8-mavericks.26` (the first with dsymutil, which the Linux
  wrapper answers from clang22's prefix) and `sdk109`. Listing `go1NN-cross@<version>` under install@v1 `products:` on a Linux
  runner installs it at `/usr/local/mavergreen/go1NN-cross` (`tests/linux-cross-test.sh` installs it through `product-tar.py`).
  Its contents are identical whichever host built it, but its `.tar.gz` bytes differ per host (the gzip implementation), so
  compare trees, not archives. Its `go.env` names `CC=bin/mavericks-cross-clang`, which patch 0020 resolves against GOROOT, so it
  works unpacked anywhere with no `CC` set (`tests/linux-cross-test.sh` builds cgo from a copy at a path with a space).
- **Linux installs the C toolchain with install@v1 `products:`**, the same as a Mac: `clang22@<version> sdk109@<tag>
  recaulk@<version>` (pins from the line's `components/*/version`), each at its pkg's prefix with that pkg's `mavergreen.plist`
  (shipyard 1.0.822 and later). The port carries no installer of its own; the refusals in `build/c-toolchain.sh` and the
  Linux wrapper name `install@v1 products:`.
- **On-target builds link without warnings.** `tests/on-target/run.sh` fails any check whose build output, stderr included,
  holds `newer than target minimum` or any `ld64.lld: warning:`, naming the line (`tests/on-target/build-output.sh`,
  proven by `tests/on-target-output-test.sh`). The lines' patch 0019 removes the `go.o has version 13.0.0` warning every
  external link used to print.
- **The trust gates are split by what each host can prove.** The lines' Linux build job runs `tests/trust-static.sh` on the
  patched `$WORK/go`: the source greps (`SecTrustCreateWithCertificates(certs, sslPolicy)`, the 10.9 fix; `keychainUnionPlatformRoots();
  handled`, patch 0016), `crypto/x509` building for linux and windows (the overlay's `!darwin` stub), and the build-tag-free
  `KeychainUnion` and fallback tests on the host. Everything that needs darwin is check 2 of `tests/on-target/run.sh` in the 10.9
  guest: >=27 `KeychainUnion` passes, `TestFallback`, `TestFallbackPanic`, `TestSSLCertEnvOverride`, patch 0018's four skips with
  their reasons, and no other skip. Together they assert everything the lines' macOS-runner `tests/trust/unit-trust.sh` did.
  *Reconsider:* if a line builds on a macOS runner again.
- **Tests that need a built product skip (77) without one** (`cross-vet.sh`, `trust-static.sh`, `linux-cross-test.sh`, `updater-test.sh`,
  `compat-guard.sh` without binaries). `tests/on-target/run.sh` is the other direction: it runs in the 10.9 guest against the
  installed toolchain and never skips.

*Reconsider:* each bullet when the rule it states stops holding; the byte-reference rule when the family has a `clang22` for
Apple Silicon.

## Not carried here

- The CA bundle itself (`vendor/cacert.pem`, curl.se's Mozilla export) is an ingredient, not a
  change — see each line's INGREDIENTS.md.
- The 10.9 legacy-support shim is an ingredient (`Mavergreen/macports-legacy-support`).

## Last verified

- golang-126: 2026-10-03: this overlay with golang-126's hook patches, applied to go1.26.8 on
  ultimate-hat (10.9.5) — `go test crypto/x509 -run 'KeychainUnion|Fallback'` passed (27
  `KeychainUnion` passes, `TestFallback` and `TestFallbackPanic` included, no SKIP or FAIL);
  `crypto/x509` builds for linux (`CGO_ENABLED=0`) and windows.
- golang-127: 2026-09-25: go1.27.1 on ultimate-hat (10.9.5) -- smoke, pure-go-link, acceptance-onbox (incl. SSL_CERT_FILE); Keychain "Never Trust" on ISRG Root X1 rejected valid-isrgrootx1.letsencrypt.org with and without SSL_CERT_FILE, and restoring Always Trust verified it; cross toolchain minos 13.0
