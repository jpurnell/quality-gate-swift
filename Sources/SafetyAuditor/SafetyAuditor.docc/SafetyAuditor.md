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
| `security.xml-external-entities` | error | 611 | An XML parser configured, or defaulted, to load external entities |
| `security.xml-entity-expansion` | warning (`XML_PARSE_HUGE`: error) | 776 | An `XMLDocument` parse with no DTD refusal; `XML_PARSE_HUGE` |
| `security.tls-no-hostname` | error | 297 | A certificate not checked against the host |
| `security.trust-handler-accepts-all` | error | 295 | A trust challenge answered without an evaluation |
| `security.trust-anchors-widened` | warning | 295 | Built-in anchors re-enabled after pinning |
| `security.ats-disabled` | error / warning | 319 | App Transport Security exceptions in `Info.plist` |
| `security.bind-all-interfaces` | error (literal at the bind) / warning | 1327 | A listener bound to every interface |
| `security.listener-auth-optional` | warning | 1188 | Authentication off by default, or switchable off from the environment, in a target that listens |

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

The two cipher rules stay quiet inside a CommonCrypto call whose operation is literally
`kCCDecrypt`: the reader of a file did not choose its cipher. Under
`weakCryptoPolicy: justified`, a `// Justification:` with a real reason on the line above clears
`weak-crypto`, `broken-cipher` and `ecb-mode`, and is recorded as an override.

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

### Who can connect

Two rules read the package's server-surface inventory (the `ServerSurface` module): every
listener and the address it binds, every handler and what stands in front of it. They are
package-wide questions — whether a `host` default is a bind address depends on whether the
package opens a socket, and whether an authenticator defaulting to `nil` matters depends on
whether its *target* does — so they run once the walk has seen every file, and each finding is
then reported, and acknowledged, in its own file.

| Rule ID | CWE | Severity | Detects |
|---------|-----|----------|---------|
| `security.bind-all-interfaces` | 1327 | error | `"0.0.0.0"`, `"::"`, `"[::]"` or `""` as the host of a `bind`, or of the `.hostPort` a `requiredLocalEndpoint` is set to: a caller cannot narrow it |
| `security.bind-all-interfaces` | 1327 | warning | The same literal as a `host`-named parameter or property default (`@Option` included), an assignment to `hostname`/`host`, or a `host:`/`hostname:`/`bindAddress:` argument that reaches a listener; an `NWListener` with no `requiredLocalEndpoint` |
| `security.listener-auth-optional` | 1188 | warning | In a target that opens a listener: an authenticator parameter or property defaulting to `nil`/`.none`, an `authRequired`-style flag defaulting to `false`, a flag read from the environment; anywhere, an authenticator passed as `nil` to a listener type |

A literal that is compared against, listed, subscripted or written in a comment chooses nothing
and is not reported. A loopback or non-literal address clears `bind-all-interfaces`; a
non-optional authenticator with no default clears `listener-auth-optional`. A listener started
inside a dependency (`MCPServer.builder()`) is the library's finding, not the caller's: the
caller cannot narrow it. Test targets are not deployments and are skipped.

Each run states what was examined, zeros included, in a `security.server-surface-coverage` note:
listeners and handlers by framework, how many bind every interface, how many have authentication
off by default, and how many findings were acknowledged.

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
