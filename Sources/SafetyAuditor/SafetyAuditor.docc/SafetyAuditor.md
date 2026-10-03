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
