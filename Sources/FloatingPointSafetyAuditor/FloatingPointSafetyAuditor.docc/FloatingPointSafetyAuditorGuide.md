# Getting Started with FloatingPointSafetyAuditor

@Metadata {
  @TechnologyRoot
}

## Overview

FloatingPointSafetyAuditor catches two of the most common floating-point bugs in Swift: exact equality comparisons that fail due to IEEE 754 rounding, and divisions that silently produce `inf` or `nan` when the divisor is zero. It uses SwiftSyntax AST walking on `Sources/` files only — test files are automatically excluded.

## What It Detects

### `fp-equality` — Exact floating-point comparison

IEEE 754 floating-point arithmetic is not exact. The classic example:

```swift
// This prints "not equal" in every IEEE 754 language
let a = 0.1 + 0.2
if a == 0.3 {
    print("equal")
} else {
    print("not equal")  // <-- this branch runs
}
```

The auditor flags `==` and `!=` operators where at least one operand appears to be floating-point.

```swift
// flagged — exact comparison on float literal
let x: Double = computeRatio()
if x == 1.0 { ... }

// flagged — both operands are FP variables
let a: Float = measure()
let b: Float = threshold()
if a != b { ... }

// flagged — constructor call indicates FP type
if Double(input) == expected { ... }
```

**Recommended fix — say which of three claims you are making.**

The checker cannot tell them apart, so it names all three rather than asserting one. Reaching for a tolerance everywhere is wrong roughly half the time, and it weakens assertions that were already correct.

| the claim | write it as | why the others are wrong |
|---|---|---|
| computed values, rounding expected | `abs(a - b) < epsilon` | an exact form fails on rounding |
| IEEE 754 equality, chosen deliberately | `a.isEqual(to: b)` | a bit-pattern comparison splits `+0.0` from `-0.0` |
| bit-identical results | `a.bitPattern == b.bitPattern` | `==` says `NaN != NaN`, so a reproducibility check with a NaN in the stream passes silently |

```swift
// computed, rounding expected
let x: Double = computeRatio()
if abs(x - 1.0) < 1e-10 { ... }

// IEEE 754 equality, deliberately. Identical behaviour to `==`, but the name
// states the claim, so it reads as a decision rather than an oversight.
if x.isEqual(to: y) { ... }

// bit-identical, including NaN and signed zero
if x.bitPattern == y.bitPattern { ... }
```

`isEqual(to:)` and `bitPattern` comparisons are never flagged. Note that a *named call* is the resolution here rather than a suppression marker: the name lives in the code and cannot drift from it, whereas a marker asserts an intent that can be wrong forever.

`abs(a - b) < epsilon` is also satisfied by a project-wide helper:

```swift
extension FloatingPoint {
    func isApproximatelyEqual(to other: Self, tolerance: Self) -> Bool {
        abs(self - other) <= tolerance
    }
}
```

### `fp-division-unguarded` — Division without zero guard

Floating-point division by zero does not trap — it silently produces `inf` or `nan`, which propagate through subsequent calculations and corrupt results.

```swift
// flagged — no guard on divisor
func normalize(_ values: [Double], by total: Double) -> [Double] {
    values.map { $0 / total }
}

// flagged — divisor is a float literal variable
let rate: Double = getRate()
let result = amount / rate
```

**Recommended fix — add a zero guard:**

```swift
// accepted — guard checks divisor before use
func normalize(_ values: [Double], by total: Double) -> [Double] {
    guard total != 0 else { return values }
    return values.map { $0 / total }
}

// accepted — the auditor recognizes these guard patterns:
//   divisor != 0
//   divisor != 0.0
//   divisor != .zero
//   divisor > 0
func safeRatio(amount: Double, rate: Double) -> Double {
    guard rate != 0.0 else { return 0.0 }
    return amount / rate
}
```

The auditor collects guarded variable names per function body. If the divisor variable name appears in any recognized guard pattern within the same function, the division is not flagged.

## Exemptions

### Sentinel-value comparisons

Exact comparison against well-known sentinel values is intentional and never flagged:

```swift
// All accepted — sentinel values where exact comparison is correct
if value == 0.0 { ... }
if result == .zero { ... }
if x.isNaN { ... }   // not flagged (method call, not == operator)
if x == .nan { ... }  // not flagged (exempt member)
if x == .infinity { ... }
if x == .pi { ... }
if x == .ulpOfOne { ... }
```

The full list of exempt member names: `zero`, `nan`, `infinity`, `greatestFiniteMagnitude`, `leastNormalMagnitude`, `leastNonzeroMagnitude`, `pi`, `ulpOfOne`, `bitPattern`, `significandBitPattern`.

`bitPattern` is exempt because it is one of the three forms the diagnostic recommends; flagging it would punish the fix.

### Per-line disable

Add `// fp-safety:disable` to any line to suppress all FP diagnostics on that line:

```swift
// This specific comparison is intentional (currency amounts stored as cents)
if totalCents == expectedCents { ... }  // fp-safety:disable
```

The marker also covers the line below it when it sits alone on a comment line:

```swift
// fp-safety:disable — currency amounts stored as cents, exact by construction
if totalCents == expectedCents { ... }
```

An inline marker never reaches the following line. `// TEST-QUALITY:` is accepted as an equivalent marker, so a suppression written for one checker holds for the other.

Suppressed findings are reported in `CheckResult.overrides` rather than dropped. A marker that suppresses nothing will not appear there — which is how you find the decorative ones.

### Whole-file disable

Place `// fp-safety:disable` on a line by itself (not inline with code) to skip the entire file:

```swift
// fp-safety:disable
// This file contains generated constants where exact comparison is valid.

import Foundation

let knownRatios: [Double] = [1.0, 2.0, 0.5, 0.25]
...
```

### Allowed files

Use `allowedFiles` in configuration to skip files by path substring:

```yaml
fp-safety:
  allowedFiles:
    - "Generated/"
    - "Vendor/"
    - "Constants.swift"
```

A file is skipped if its relative path contains any of the listed strings.

### Test files

Files under `Tests/` are always excluded. The auditor only scans `Sources/`.

## Configuration

Minimal configuration (all defaults):

```yaml
fp-safety: {}
```

Full configuration:

```yaml
fp-safety:
  allowedFiles:
    - "Generated/Constants.swift"
    - "Vendor/"
  checkDivisionGuards: true
```

To disable only the division-guard rule while keeping equality checks:

```yaml
fp-safety:
  checkDivisionGuards: false
```

## Integration

### CLI usage

Run as part of the full quality gate:

```bash
quality-gate
```

Run only the floating-point safety auditor:

```bash
quality-gate --checkers fp-safety
```

### Programmatic usage

The auditor exposes a single-source API for testing and tooling integration:

```swift
let auditor = FloatingPointSafetyAuditor()
let result = try await auditor.auditSource(
    sourceCode,
    fileName: "MyFile.swift",
    configuration: .default
)
for diagnostic in result.diagnostics {
    print("\(diagnostic.filePath):\(diagnostic.lineNumber): \(diagnostic.message)")
}
```

### CI integration

```yaml
steps:
  - name: FP safety check
    run: quality-gate --checkers fp-safety --strict
```

Both rules emit warnings. Use `--strict` to promote them to gate failures when precision correctness is critical.
