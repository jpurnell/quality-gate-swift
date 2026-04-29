# ``FloatingPointSafetyAuditor``

Catches floating-point precision bugs: exact equality comparisons and unguarded divisions.

## Overview

FloatingPointSafetyAuditor uses SwiftSyntax to walk Swift source files under `Sources/` and flag two classes of floating-point bugs that compile cleanly but produce incorrect results at runtime. Both rules emit warnings rather than errors because heuristic detection from syntax alone cannot guarantee operand types — false positives are preferable to silent precision bugs.

The auditor uses conservative heuristics to determine whether an expression involves floating-point values. It recognizes float literals (`3.14`, `1.0`), explicit type annotations (`let x: Double`), variables initialized from float literals, member access on known FP type names (`Double.random(...)`), and constructor calls (`Double(someValue)`). The recognized type names are `Double`, `Float`, `CGFloat`, `Float16`, `Float80`, and `Decimal`.

Test files (paths containing `/Tests/` or starting with `Tests/`) are automatically excluded from analysis. The auditor only scans files under the `Sources/` directory.

### Detected rules

| Rule ID | What it flags | Severity |
|---------|---------------|----------|
| `fp-equality` | `==` or `!=` on floating-point operands | warning |
| `fp-division-unguarded` | Division by a floating-point value without a visible zero guard | warning |

### fp-equality

Exact floating-point comparison is almost always a bug. IEEE 754 arithmetic means that `0.1 + 0.2 != 0.3` in every language, Swift included. This rule flags `==` and `!=` operators where at least one operand appears to be floating-point.

Several sentinel-value comparisons are exempt because exact equality is intentional:

- Literal `0.0` (and variants `0.00`, `0.000`, `.0`)
- `.zero`
- `.nan`
- `.infinity`
- `.greatestFiniteMagnitude`
- `.leastNormalMagnitude`
- `.leastNonzeroMagnitude`
- `.pi`
- `.ulpOfOne`

### fp-division-unguarded

Division by a floating-point value that could be zero produces `inf` or `nan`, which propagate silently through calculations. This rule flags `/` and `/=` operators where the divisor appears to be floating-point and no zero guard is visible in the enclosing function scope.

The auditor recognizes guard patterns of the form `variable != 0`, `variable != 0.0`, `variable != .zero`, and `variable > 0`. When the divisor variable appears in any of these patterns within the same function body, the division is considered guarded and is not flagged.

### Suppression

Per-line suppression is available via the `// fp-safety:disable` comment:

```swift
let ratio = a / b  // fp-safety:disable
```

Whole-file suppression works by placing `// fp-safety:disable` on a line by itself (not inline with code). This skips the entire file.

### Out of scope

- Cross-file type inference (would require IndexStore or the type checker)
- Integer division detection (separate concern, handled by SafetyAuditor)
- Flagging `Float`-to-`Double` implicit promotions
- Detecting accumulation drift in loops (planned for v2)

## Configuration

```yaml
fp-safety:
  allowedFiles:
    - "Generated/Constants.swift"
    - "Vendor/"
  checkDivisionGuards: true
```

- **`allowedFiles`** (default: `[]`) — File path substrings to exclude from FP safety checks. A file is skipped if its path contains any of these strings.
- **`checkDivisionGuards`** (default: `true`) — Whether to enable the `fp-division-unguarded` rule. Set to `false` if your codebase has its own division-safety patterns that produce false positives.

## Topics

### Essentials

- ``FloatingPointSafetyAuditor/check(configuration:)``
- ``FloatingPointSafetyAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:FloatingPointSafetyAuditorGuide>
