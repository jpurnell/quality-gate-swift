# ``FloatingPointSafetyAuditor``

Catches floating-point precision bugs: exact equality comparisons and unguarded divisions.

## Overview

FloatingPointSafetyAuditor uses SwiftSyntax to walk Swift source files under `Sources/` and flag two classes of floating-point bugs that compile cleanly but produce incorrect results at runtime. Both rules emit warnings rather than errors because heuristic detection from syntax alone cannot guarantee operand types — false positives are preferable to silent precision bugs.

The auditor uses conservative heuristics to determine whether an expression involves floating-point values. It recognizes float literals (`3.14`, `1.0`), explicit type annotations (`let x: Double`), parameter types written in a signature (`func f(d: Double)` — read by the division rule, for the divisor), variables initialized from float literals, member access on known FP type names (`Double.random(...)`), and constructor calls (`Double(someValue)`). The recognized type names are `Double`, `Float`, `CGFloat`, `Float16`, `Float80`, and `Decimal`.

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

The auditor reads the checks a function body makes and where it makes them. A division is not flagged when something *before it* asked whether its divisor is zero: `d != 0`, `d > 0`, `n >= 1`, `d == 0 ? 0 : x / d`, `abs(d) > .ulpOfOne`, `!d.isZero`, or — for a divisor of `xs.count` — any test of `xs.isEmpty`. A check on `values.count` covers `let count = Double(values.count)`. A check written after the division does not count. <doc:FloatingPointSafetyAuditorGuide> has the full list.

A divisor that cannot be zero is not flagged either: a nonzero literal or literal arithmetic (`365.25 / 12.0`, `UInt64(1) << 32`), a `let` or `static let` bound to one in the same file, `.pi` and the integer maxima, `max(x, 1)`, and arithmetic on a value a guard dominates — `n - 1` under `guard n > 1`, `6 * area` under `guard abs(area) > 1e-10`, `1.0 + exp(x)`. `max(x, .leastNonzeroMagnitude)` **is** flagged: the divisor is not zero and the quotient is infinite, which is the defect the rule exists for.

A finding is placed on the line of the `/` or `/=` itself. An expression spread over several lines can hold several divisions, and each is reported — and suppressed — on its own line.

### Suppression

Per-line suppression is available via the `// fp-safety:disable` comment:

```swift
func ratio(_ a: Double, to b: Double) -> Double {
    a / b  // fp-safety:disable
}
```

The marker also applies to the line below it when it sits on a comment-only line, which is how a long justification is written. It does **not** reach downward from a trailing marker — an inline marker suppresses only its own line.

Whole-file suppression works by placing `// fp-safety:disable` on a line by itself (not inline with code). This skips the entire file.

`// fp-safety:disable` is the canonical marker for this rule family. The legacy `// TEST-QUALITY:` marker is honoured too, by both this auditor and `TestQualityAuditor`: `fp-equality` and `exact-double-equality` are one rule, so a marker that silences it from one checker silences it from the other. See ``FloatingPointSuppression``.

Suppressed findings are recorded in the `overrides` array of the `CheckResult` rather than discarded, so a marker that is doing nothing can be found.

### A second checker in this module

``FallbackAuditor`` (`--check fallback`) lives here because it needs the same kind of type evidence, and asks a different question: not whether a divisor is guarded, but what becomes of a value that is not a number. It reports an integer conversion that traps on one, a clamp that returns a bound for one, and a chain of comparisons that sorts one into its last arm; and it asks, without failing the run, about a guard that answers for one. See <doc:FallbackAuditorGuide>.

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
- ``FallbackAuditor``

### Guides

- <doc:FloatingPointSafetyAuditorGuide>
- <doc:FallbackAuditorGuide>
