# ``SafetyAuditor``

Scans Swift source files for forbidden patterns that could cause crashes in production.

## Overview

SafetyAuditor uses SwiftSyntax to parse and analyze Swift source code, detecting patterns that could lead to runtime crashes. Unlike compiler warnings, these checks focus specifically on safety-critical patterns.

### Detected Patterns

| Pattern | Risk | Rule ID |
|---------|------|---------|
| `value!` | Force unwrap crashes if nil | `force-unwrap` |
| `as!` | Force cast crashes if type mismatch | `force-cast` |
| `try!` | Force try crashes if error thrown | `force-try` |
| `fatalError()` | Unconditional crash | `fatal-error` |
| `precondition()` | Crashes in release if false | `precondition` |
| `assertionFailure()` | Crashes in debug builds | `assertion-failure` |
| `unowned` | Crashes if accessed after deallocation | `unowned` |
| `while true` | Potential infinite loop | `infinite-loop` |

### Security rules

The same pass runs the `security.*` rules. Their CWE lists and OWASP columns live in
``SecurityRuleManifest``; the severity here is what a finding is reported at.

| Rule ID | Severity | CWE | What it detects |
|---------|----------|-----|-----------------|
| `security.hardcoded-secret` | warning | 798 | Secret-named variable assigned a string literal |
| `security.command-injection` | error | 78 | A shell run with `-c` and a command string assembled at runtime |
| `security.weak-crypto` | warning | 328 | MD5 / SHA-1 hashing |
| `security.insecure-transport` | warning | 319 | `http://` URLs other than local hosts |
| `security.eval-js` | error | 95 | `evaluateJavaScript` with dynamic input |
| `security.sql-injection` | error | 89 | Interpolation in an SQL-executing call |
| `security.insecure-keychain` | warning | 922 | Keychain items readable while the device is locked |
| `security.tls-disabled` | error | 295, 298 | Certificate validation disabled or weakened |
| `security.path-traversal` | warning | 22 | A chosen segment joined onto a directory and used unchecked |
| `security.path-containment-by-prefix` | error | 22, 187 | A containment check written as a prefix with no separator |
| `security.archive-path-escape` | error | 22 | An archive entry's name joined onto a destination and written unchecked; `unzip -:`, `tar -P` |
| `security.archive-symlink` | error | 59 | A link whose target an archive entry chose, created unchecked; ZIPFoundation's symlink check switched off |
| `security.ssrf` | warning | 918 | `URL(string:)` from dynamic input |
| `security.broken-cipher` | error | 327 | DES, 3DES, RC4, RC2, CAST or Blowfish constants; CryptoSwift Blowfish, Rabbit |
| `security.ecb-mode` | error | 327 | ECB mode (`kCCOptionECBMode`, `kCCModeECB`, CryptoSwift `ECB()`) |
| `security.homemade-digest` | warning | 1240 | A digest-named function of a secret that calls no primitive |
| `security.hardcoded-key` | error | 321 | Literal key bytes given to a cipher, MAC or key initialiser; a PEM private key in a literal |
| `security.static-iv` | error | 329, 1204, 323 | A nil or literal IV when encrypting; a literal or held AEAD nonce |
| `security.weak-kdf` | error (unchecked PBKDF2: warning) | 916 | PBKDF2 below 210,000 rounds; a bare SHA-2 digest of a password |
| `security.weak-key-size` | error | 326 | RSA below 2048 bits; a symmetric key below 128 bits |
| `security.xml-external-entities` | error | 611 | An XML parser configured, or defaulted, to load external entities |
| `security.xml-entity-expansion` | warning (`XML_PARSE_HUGE`: error) | 776 | An `XMLDocument` parse with no DTD refusal; `XML_PARSE_HUGE` |
| `security.tls-no-hostname` | error | 297 | A certificate not checked against the host |
| `security.trust-handler-accepts-all` | error | 295 | A trust challenge answered without an evaluation |
| `security.trust-anchors-widened` | warning | 295 | Built-in anchors re-enabled after pinning |
| `security.ats-disabled` | error / warning | 319 | App Transport Security exceptions in `Info.plist` |

A finding is acknowledged with `// SECURITY: <reason>` on its line or the line above. The reason
must pass the same validator as `concurrency.*` justifications, and an accepted acknowledgement
is recorded as an override rather than dropped.

### Cryptography rules

The security visitor's crypto rules read what a call is *given*, not only what it is called:

| Rule ID | CWE | Severity | What it detects |
|---------|-----|----------|-----------------|
| `security.weak-crypto` | 328 | warning | `CC_MD5`, `CC_SHA1`, `Insecure.MD5` / `Insecure.SHA1` |
| `security.broken-cipher` | 327 | error | DES, 3DES, RC4, RC2, CAST or Blowfish selected by constant; CryptoSwift `Blowfish`, `Rabbit` |
| `security.ecb-mode` | 327 | error | `kCCOptionECBMode`, `kCCModeECB`; CryptoSwift `ECB` as a block mode |
| `security.homemade-digest` | 1240 | warning | A digest-named function of a secret whose body calls no primitive |
| `security.hardcoded-key` | 321 | error | Literal-derived bytes to `SymmetricKey(data:)`, the key of `CCCrypt` / `CCCryptorCreate` / `CCHmac`, a `P256`/`P384`/`P521`/`Curve25519`/`_RSA` `PrivateKey(raw/pem/derRepresentation:)` or a CryptoSwift `key:`; a PEM private key literal with a body |
| `security.static-iv` | 329, 1204, 323 | error | `nil` or literal IV to an encrypting `CCCrypt` / `CCCryptorCreate` outside ECB; `AES._CBC.encrypt` with a literal IV; a literal `AES.GCM` / `ChaChaPoly` nonce; a nonce held in a `static let` or file-scope `let` passed to `seal`; a CryptoSwift literal `iv:` |
| `security.weak-kdf` | 916 | error | `CCKeyDerivationPBKDF` below 210,000 rounds; `unsafeUncheckedRounds:` (warning, error below the floor); `SHA256`/`384`/`512.hash` or `CC_SHA*` of a password-named value |
| `security.weak-key-size` | 326 | error | `kSecAttrKeySizeInBits` below 2048 unless the same literal asks for an EC key; `_RSA` below 2048 bits; `SymmetricKey` below 128 bits |

The two cipher rules stay quiet inside a CommonCrypto call whose operation is literally
`kCCDecrypt`: the reader of a file did not choose its cipher. `static-iv` does the same, and also
ignores `AES._CBC.decrypt` and a nonce rebuilding a `SealedBox` to open. `hardcoded-key` does
not: a key in the source is readable whichever way the call goes. Under
`weakCryptoPolicy: justified`, a `// Justification:` with a real reason on the line above clears
`weak-crypto`, `broken-cipher`, `ecb-mode`, `hardcoded-key` and `static-iv`, and is recorded as an
override.

"Literal-derived" is syntactic: a string, integer-array, `Data(repeating:count:)` or
`Data(count:)` literal, any of those through `Data(…)`, `Array(…)`, `.utf8`, `.data(using:)`,
`Data(base64Encoded:)` or `Data(hexString:)`, or a name bound by a `let` in the same file to one
of those. The `let` is found lexically, so a parameter that shadows a literal constant is not
the constant. A key copied into a buffer and the buffer passed is not seen.

`hardcoded-secret` (CWE-798) reads a name: a secret-named binding assigned a string literal.
`hardcoded-key` (CWE-321, a child of 798) reads a use: literal bytes where a key belongs. When a
secret-named literal is that key — `let apiSecret = "…"` passed to `SymmetricKey(data:)`, or a
PEM private key — only `hardcoded-key` reports it, so one literal is one finding. With
`hardcoded-key` disabled, `hardcoded-secret` reports it as before.

The four key rules do not report in a test target. A known-answer test needs a fixed key, IV
and nonce, a fast test wants few rounds and a small key, and the gate's determinism rules require
a test's inputs to be fixed — so `Tests/` is where a test vector belongs, and moving it there
clears the finding.

### What a client agrees to trust

Five security rules cover certificate validation and transport policy. The four that read Swift
report through the same `// SECURITY: <reason>` acknowledgement as every other security rule;
`security.ats-disabled` reads a property list instead.

| Rule ID | CWE | Severity | Detects |
|---------|-----|----------|---------|
| `security.tls-disabled` | 295, 298 | error | A client's `certificateVerification` set or passed as `.none`, including either arm of a ternary and a typed local; `SecTrustSetExceptions`; Alamofire's `DisabledTrustEvaluator`; `allowsExpiredCertificates`/`allowsExpiredRoots` set to `true` |
| `security.tls-no-hostname` | 297 | error | `.noHostnameVerification` on a client configuration; an evaluator built with `validateHost: false`; `SecPolicyCreateSSL(true, nil)`; a basic X.509 policy given to `SecTrustSetPolicies` |
| `security.trust-handler-accepts-all` | 295 | error | A `urlSession`/`webView` challenge handler answering `.useCredential` with `URLCredential(trust:)` and using the result of no evaluation; a `sec_protocol_options_set_verify_block` closure that always completes `true` |
| `security.trust-anchors-widened` | 295 | warning | `SecTrustSetAnchorCertificatesOnly(_, false)`, which undoes pinning |
| `security.ats-disabled` | 319 | error / warning | App Transport Security exceptions in `Info.plist` |

A server configuration is exempt from both mode findings. There `certificateVerification`
governs *client* certificates: `.none` is NIOSSL's default for a server not doing mutual TLS,
and `.noHostnameVerification` is what its own `makeServerConfigurationWithMTLS` sets, since a
server has no hostname to compare a client certificate against.

`security.ats-disabled` reads every `Info.plist` (and `*-Info.plist`) the safety walk reaches,
XML or binary. `NSAllowsArbitraryLoads` is an error, or a warning when a key that makes the
system ignore it is also present. Arbitrary loads in web content or for media, an exception
domain allowing cleartext HTTP, and an exception domain's minimum TLS version below 1.2 are
warnings. A property list keeps no comments, so an insecure domain is acknowledged in
configuration instead, and recorded as an override:

```yaml
security:
  atsAllowedInsecureDomains:
    - legacy.example.com
```

There is no acknowledgement for the global key. An app that needs it removes
`security.ats-disabled` from `enabledRules`, in a file with history.

### What it scans

The whole repository, minus the configured exclusions — not a hardcoded `Sources/`. That
distinction cost real coverage: unguarded force-unwraps in `Tests/`, in `Plugins/`, and at the
package root were never examined, and a test that crashes on a nil takes a suite down exactly as
thoroughly as shipping code takes an app down. Nested packages are skipped: a vendored dependency
with its own `Package.swift` belongs to whoever maintains it.

Every run prints a `safety.coverage` note with the number of files actually examined. That number
is computed rather than claimed, which is the point — a scope written into prose goes stale
silently, and this one had.

### Exemptions

Code that intentionally uses these patterns can be marked with `// SAFETY:` comments:

```swift
final class SubmitButton {}

let optional: Int? = 42
let sender: Any = SubmitButton()

// SAFETY: Guaranteed non-nil after initialization
let value = optional!

let view = sender as! SubmitButton // SAFETY: Type guaranteed by IB connection
```

The exemption comment can appear on the same line or the line immediately above the violation.

### Custom Exemption Patterns

Configure custom exemption patterns via `.quality-gate.yml`:

```yaml
safety_exemptions:
  - "// SAFETY:"
  - "// @unsafe:"
```

## Topics

### Essentials

- ``SafetyAuditor/check(configuration:)``
- ``SafetyAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:ExemptionGuide>
