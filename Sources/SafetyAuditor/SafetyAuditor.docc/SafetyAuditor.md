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
