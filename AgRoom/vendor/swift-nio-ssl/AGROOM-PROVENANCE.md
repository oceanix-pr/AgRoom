# SwiftNIO SSL provenance

Vendored from official SwiftNIO SSL tag `2.37.5`, Apache-2.0.
https://github.com/apple/swift-nio-ssl/tree/2.37.5

The official release archive SHA-256 is `152feb0de63552e38c737e0917351bf336a094a3146587e7489b03bad4b2a7b4`.
Upstream license notices are retained. Local manifest and analyzer compatibility
changes are documented below; source and regression-test changes are recorded in
`AGROOM-ANALYZER.patch` relative to this release.
BoringSSL provenance and licenses are recorded by upstream in Sources/CNIOBoringSSL.

Local manifest adjustments: NIOSSL enables the compiler's `CheckImplementationOnly`
feature so implementation-only C imports are checked without library evolution.
The vendored CNIOBoringSSL C/C++ target alone opts out of Xcode's macOS
`-Wshorten-64-to-32` advisory for upstream's legacy integer API bridges. This is a
target-scoped warning policy, not a fix or suppression in application code; it
does not change cryptographic operations, TLS verification, or other diagnostics.

## Analyzer compatibility patch

The local source patch addresses Xcode's dead-store, zero-divisor and
uninitialized-value diagnostics without disabling analyzer checkers:

- Remove assignments whose values are never consumed, including completed
  Curve25519 scalar-reduction limbs and overwritten PEM callback lengths.
  Explicit `OPENSSL_cleanse` operations remain in place.
- Guard each PKCS#12 padded-component copy with its original component length.
  Empty components already have zero padded length; the guards make the nonzero
  modulo divisor explicit and preserve the empty/absent-password behavior.
- Zero-initialize the decryption nonce buffer before its existing fixed/variable
  nonce assembly. Valid TLS nonce bytes, cipher selection and authentication
  checks retain their existing behavior.
- Add an RFC 8032 Ed25519 signature vector with tamper rejection and a PKCS#12
  empty/absent-password round trip to the existing upstream test files.

For upgrades, check whether the diagnostics still reproduce before carrying the
patch forward. Review changed upstream code rather than applying hunks with fuzz.
From a fresh checkout of the recorded release, `patch --dry-run -p1 < AGROOM-ANALYZER.patch`
checks the patch paths and context. From the app directory, run
`sh scripts/verify-boringssl-analyzer.sh` with the full Xcode toolchain selected to
check debug and release paths with Clang's shallow and deep analyzers. Run the affected
upstream NIOSSL tests using the app's locked dependency versions, and rebuild and
analyze the AgRoom Xcode scheme. Do not replace these checks with global warning
suppression.
