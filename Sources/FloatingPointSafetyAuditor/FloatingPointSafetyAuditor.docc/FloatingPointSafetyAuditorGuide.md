# Getting Started with FloatingPointSafetyAuditor


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
// stand-ins for whatever your project computes
func computeRatio() -> Double { 0.75 }
func measure() -> Float { 1.5 }
func threshold() -> Float { 1.5 }
let input = 1
let expected = 1.0

// flagged — exact comparison on float literal
let x: Double = computeRatio()
if x == 1.0 { print("exactly one") }

// flagged — both operands are FP variables
let measured: Float = measure()
let limit: Float = threshold()
if measured != limit { print("over budget") }

// flagged — constructor call indicates FP type
if Double(input) == expected { print("matches expected") }
```

### What counts as a floating-point operand

Because SwiftSyntax gives syntax and not types, the answer is a heuristic. Three limits keep it from inventing an answer:

**A static member on a floating-point type is only floating-point if it is on the allowlist** — `pi`, `infinity`, `nan`, `signalingNaN`, `ulpOfOne`, `greatestFiniteMagnitude`, `leastNormalMagnitude`, `leastNonzeroMagnitude`, `zero`. Anything else is unknown. `Double.dimension` is an `Int` arriving from a `VectorSpace` conformance, and `Double.dimension == 1` is not a floating-point comparison.

**A name binding does not outlive the declaration that introduced it.** The name→type map is scoped to the enclosing function, closure, computed property or type body. A local `result` holding an `Int` is not floating-point merely because an unrelated test in the same file wrote `let result: Double`.

**A collection of floating-point values is a floating-point operand.** `[Double]`, `[Float]`, `ArraySlice`/`ContiguousArray`/`Array` of those, and array literals built from float literals. `==` on them compares elementwise with `==`, so the diagnostic says so and the fixes it names are elementwise:

```swift
import Testing

func distributionGamma(r: Int, λ: Double, seed: UInt64) -> Double {
    Double(r) * λ * Double(seed % 7)
}

func block(_ draw: (UInt64) -> Double, seed: UInt64) -> [Double] {
    (0..<4).map { draw(seed &+ UInt64($0)) }
}

// flagged — `gammaA == gammaB` on [Double] compares elementwise; a NaN anywhere
// in either stream makes this assertion pass while the property is broken
let gammaA = block({ distributionGamma(r: 4, λ: 2.0, seed: $0) }, seed: 42)
let gammaB = block({ distributionGamma(r: 4, λ: 2.0, seed: $0) }, seed: 42)
#expect(gammaA == gammaB, "Seed 42 must reproduce exactly")

// accepted — the count is part of the claim, and bit-identity is the claim
#expect(gammaA.count == gammaB.count)
#expect(zip(gammaA, gammaB).allSatisfy { $0.bitPattern == $1.bitPattern })
```

That example only resolves because the helper declares its return type in the same file. **Return types are propagated within one file**, so `let gammaA = block(...)` picks up `block`'s declared `-> [Double]`. It is deliberately narrow: explicit return clauses only, bare call targets only (`f(x)`, never `receiver.f(x)`), one file only, and a name declared twice with *different* return types is dropped rather than guessed at. Two declarations that agree are kept — the answer does not depend on which overload the compiler picks, so it is not a guess.

`x == nil` is never a floating-point comparison, whatever the optional wraps.

**Recommended fix — say which of three claims you are making.**

The checker cannot tell them apart, so it names all three rather than asserting one. Reaching for a tolerance everywhere is wrong roughly half the time, and it weakens assertions that were already correct.

| the claim | write it as | why the others are wrong |
|---|---|---|
| computed values, rounding expected | `abs(a - b) < epsilon` | an exact form fails on rounding |
| IEEE 754 equality, chosen deliberately | `a.isEqual(to: b)` | a bit-pattern comparison splits `+0.0` from `-0.0` |
| bit-identical results | `a.bitPattern == b.bitPattern` | `==` says `NaN != NaN`, so a reproducibility check with a NaN in the stream passes silently |

```swift
// computed, rounding expected
let ratio: Double = computeRatio()
let target: Double = 1.0
if abs(ratio - 1.0) < 1e-10 { print("one, within tolerance") }

// IEEE 754 equality, deliberately. Identical behaviour to `==`, but the name
// states the claim, so it reads as a decision rather than an oversight.
if ratio.isEqual(to: target) { print("IEEE 754 equal") }

// bit-identical, including NaN and signed zero
if ratio.bitPattern == target.bitPattern { print("same bits") }
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
func getRate() -> Double { 1.5 }
let amount = 100.0

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
func normalizeGuarded(_ values: [Double], by total: Double) -> [Double] {
    guard total != 0 else { return values }
    return values.map { $0 / total }
}

// accepted — the auditor recognizes these guard patterns, written before the division:
//   divisor != 0, divisor != 0.0, divisor != .zero     (and divisor == 0, in either branch)
//   divisor > 0, 0 < divisor, divisor > 3              (a literal threshold)
//   divisor >= 1, 4 <= divisor                         (>= needs a literal above zero)
//   divisor <= 0                                       (the same question, asked the other way)
//   abs(divisor) > .ulpOfOne, !divisor.isZero
//   !values.isEmpty, values.isEmpty == false, values.isEmpty ? … : …   (guards values.count)
func safeRatio(amount: Double, rate: Double) -> Double {
    guard rate != 0.0 else { return 0.0 }
    return amount / rate
}
```

The auditor reads the checks each function body makes, and where it makes them. A division is not flagged when something **before it** — in the same body or an enclosing one — asked whether its divisor is zero. Four things follow from that:

- **Order.** A check written after the division did not protect it. `let r = x / Double(n); if n > 0 { return r }` is flagged.
- **Either sense.** `if d == 0 { return 0 }`, `d == 0 ? 0 : x / d` and `xs.isEmpty ? 0 : sum / Double(xs.count)` are guards. What is recorded is that the question was asked, not which way it was answered — `if d != 0 { log() }` has always cleared a later division, and still does. Whether the answer was acted on needs branch structure the auditor does not have.
- **Aliases.** `let count = Double(values.count)` is `values.count` under another name, so a guard on either clears a division by either.
- **A threshold is a literal.** `n > 0`, `n >= 2` and `abs(d) > .ulpOfOne` are guards; `n >= 0` is not, and neither is `segLen > n` or `d != 1` — a comparison between two values says nothing about zero. A threshold that is a constant of this file is read as the literal it names: `d > epsilon` is a guard when `let epsilon = 1e-9` is in reach, and so is `count >= Swift.max(1, minimum)`, which is at least one whatever `minimum` is.

#### A divisor that cannot be zero needs no guard

- **A literal, or arithmetic on literals.** `100.0`, `Double(60)`, `(365.25 / 12.0 * 86_400.0)`, `Double(UInt64(1) << 32)`. The arithmetic is folded under both readings a literal has, and has to be nonzero under both: `(1 / 2)` is `0.5` between `Double`s and `0` between `Int`s, and is flagged. A shift is folded at the width of the type that was written. Where none was, the width is taken as 32 bits, because `Int` is 32 bits on arm64_32: `Double(1 << 53)` is flagged, and should be — built for an Apple Watch before Series 9 it is `0.0`, folded by the compiler without a diagnostic. `Double(UInt64(1) << 53)` says what was meant.
- **A named constant.** A local `let`, a stored `let` with an initializer, or a `static let` — read by bare name, `Self.name` or `Type.name` when the type is declared in this file — and a file-scope `let` used outside any type. A `var` or `static var` is not read, nor is a computed property, nor a member of a type declared elsewhere. A declaration nearer the use shadows one further out, whatever it holds: a closure parameter named `d` hides a constant `d`.
- **A standard-library constant.** `.pi`, `Double.pi`, `UInt64.max` and the other integer maxima, `.greatestFiniteMagnitude`, `.ulpOfOne`.
- **`max(x, 1)`**, `Swift.max(1, x)`, and a `let` bound to either: at least the largest floor among its arguments. `max(n, 0)` and `max(n, -1)` can be zero and are flagged.
- **Arithmetic on a value a guard dominates.** `n - 1` under `guard n > 1` or `n >= 2`; `count + 1` under `count >= 1`; `1.0 + exp(x)`; `i + 1` where `i` is the variable of `for i in 0..<n` or the index of `xs.enumerated()`; `n` itself inside `for _ in 0..<n`. A product is accepted only where it cannot underflow: `6 * area` and `Double(n) * rate` are, because a factor of magnitude at least one can only make the other larger. `a * b` under `guard a > 0, b > 0` is flagged — `1e-200 * 1e-200` is zero — and so is `0.5 * area`.

**`max(x, .leastNonzeroMagnitude)` is flagged, and so is `.leastNormalMagnitude`.** The divisor is not zero. The quotient is infinite, or near enough: `1.0 / .leastNonzeroMagnitude` overflows. A floor that turns a division by zero into a division by 5e-324 has changed the spelling of the defect and nothing else, and it reads like a guard to whoever comes next. Floor the divisor at a value the result can survive (`max(x, 1)`, `max(x, .ulpOfOne)`), or test for zero and return what the caller should see. Where `x` is already known to be at least one, the `max` is accepted on that account and the floor is dead code.

Arithmetic on a bound is only worth anything while the bound is true, so these shapes are held to more than "the question was asked before the division":

- **Dominance.** A `guard` covers what follows it in its block. An `if` covers its own body; when the test is the only condition it covers the opposite in its `else`, and in what follows it when its body always leaves — `if abs(r) < 1e-10 { throw … }` is a guard on `r` from the next line on, and `guard !(abs(x) < eps)` is one too. A ternary covers each arm. `if n > 1 { log() }` followed by `x / Double(n - 1)` is flagged.
- **Nothing changed in between.** An assignment to the value, an `inout` pass, a redeclaration of its name, or a method called on it that is not known to be non-mutating ends the claim. So does a change later in a loop the guard sits outside of, and a change made by a closure or local function of the same body wherever it is written — `let reset = { n = 0 }` can sit above the guard and run below it. A change to `state.a` does not end a claim about `state.b`.
- **A count carried through a transform.** `guard !xs.isEmpty` reaches `ys.count` for `let ys = xs.map { … }` (and `sorted`, `reversed`, `shuffled`, `Array(xs)`). It does not reach `xs.filter { … }.count`.
- **A Bool predicate of this file.** `guard bond.isSchedulable` asserts the conditions of the leading `guard … else { return false }` statements of `isSchedulable`, when `bond`'s type is written (`bond: BondMarketData`) and that type declares the property in this file.

What these do not see, stated so that nobody has to discover it: a stored property changed by another method of the type that is called between the guard and the division; a `let` reference to a class instance changed through its own methods; a conversion to `Float` of a positive value too small for a `Float`; and a function named `max`, `abs`, `exp` or `sqrt` that is not the standard one. A computed property is not followed even when every `return` in it is a nonzero literal — `Double(frequency.periodsPerYear)` stays flagged — because the property is found by name, and the name does not say which type's it is.

#### Where a finding is placed

On the `/` or `/=`. A division used to be reported at the first line of the expression it is part of, so two divisions in one expression spread over several lines were both reported there, and a marker on that line silenced both — including the one its reason did not describe. Each is now reported on its own line. A marker or a baseline entry attached to the first line of a multi-line expression, for a division whose operator is on a later line, has to move to that line.

This rule holds a **higher evidence bar** than `fp-equality` for what counts as a floating-point operand. A **divisor** is examined when its type is written down: an annotation on a `let` or a stored property, a parameter's type in a signature (`Double`, `Float`, `CGFloat`, `Float16`, `Float80`, `Decimal` — through `inout`, `borrowing` and `consuming`, with or without a default value), a literal, a conversion, an allowlisted static member — or a local bound to one of those. A name carries exactly the evidence of the expression it names, so `let d = Double(n); x / d` is examined just as `x / Double(n)` is, and `let t = total; x / t` just as `x / total` is.

What it does not read:

- **A function's return type.** A local bound from a call to a file-local function returning `Double` is unexamined.
- **Arithmetic as evidence of type**, on either side of the `=`. `x / (a - b)` and `let d = a - b; x / d` are both unexamined when nothing else says the division is floating-point. Arithmetic in a divisor that *is* examined — `1.0 / (a - b)` — is read as described above.
- **A parameter in the numerator.** A literal or a conversion on the left of the `/` is evidence for the whole division — `100.0 / c.scale` is examined — but a parameter there is not: `x / c.scale` and `x / (a - b)` are unexamined. Counting it would report divisors that are arithmetic or calls, which no guard the auditor reads could clear without first giving them a name.
- **A generic parameter** (`T: BinaryFloatingPoint`), **a typealias** (`TimeInterval`), and a stored property declared *below* its use, reached through `self.`, or used from an extension.

`fp-equality` does not read a parameter's type either: `func f(x: Double, d: Double) -> Bool { x == d }` is not reported.

**Where the guard has to be: in the function that divides.** A floating-point division by zero does not trap — it returns `inf` or `nan` and carries on — so a contract the function does not state in code is enforced by nothing. The auditor reads one file and no call graph: a check in the caller is invisible to it, and a `- Precondition:` line in a doc comment is a claim about callers, not a check. `precondition(d != 0)` and `assert(d > 0)` both count, because the bar is that the question was asked before dividing, not how the answer is handled. For a private helper whose callers have all checked, `assert` is the intended answer: it costs nothing in release and turns "validated by caller" from a comment into something a debug build verifies.

**Top-level code is a body.** A script, a `main.swift` or a playground page asks the question in the same spellings: `let mean = count > 0 ? sum / count : 0`, an `if d > 0 { … }` around the division, or a `guard d > 0 else { exit(1) }` above it all clear a division at file scope, in the same order as anywhere else. Only top-level *statements* are read this way. A guard inside a function, or inside a member of a type or extension declared at file scope, answers for that body and not for the program around it. The `fallback.*` rules read top-level code the same way, through the same collector.

**A declaration that is not floating-point shadows one that is.** Inside `func f(total: Int, rate: Int)`, `total / rate` is integer division even when the enclosing type has a stored `rate: Double`. An untyped closure parameter (`{ d in 10 / d }`) and a local annotated with another type shadow in the same way.

**A declaration of `/` or `/=` is not a use of it.** A division inside `static func / (lhs: V, rhs: Double) -> V` is not examined: that function *is* division for the type, and the contract belongs to whoever writes `v / s`.

The two rules ask different questions of the same operand. `fp-equality` asks which of three claims an `==` is making, and is worth raising whenever the operand is plausibly floating-point. `fp-division-unguarded` asks whether a divisor could be zero, and its answer is a guard added to shipping code.

An earlier version of this page said the rule "does not follow inference chains" and named a local bound from `Double(count)` as one. That lumped two things together. The return-type chain is inference and is still refused. A conversion bound to a `let` one line above its use is a conversion written at the site, and refusing it meant a division was examined or not depending on whether its divisor had a name.

## Exemptions

### Sentinel-value comparisons

Exact comparison against well-known sentinel values is intentional and never flagged:

```swift
let value: Double = 0.0

// All accepted — sentinel values where exact comparison is correct
if value == 0.0 { print("zero") }
if result == .zero { print("zero") }
if x.isNaN { print("nan") }   // not flagged (method call, not == operator)
if x == .nan { print("never true") }  // not flagged (exempt member)
if x == .infinity { print("infinite") }
if x == .pi { print("pi") }
if x == .ulpOfOne { print("one ulp") }
```

The full list of exempt member names: `zero`, `nan`, `signalingNaN`, `infinity`, `greatestFiniteMagnitude`, `leastNormalMagnitude`, `leastNonzeroMagnitude`, `pi`, `ulpOfOne`, `bitPattern`, `significandBitPattern`.

This is the static-member allowlist plus the bit-inspection members, and it is *derived* from that allowlist rather than maintained beside it. A static member that **is** the floating-point type is by construction a sentinel — there is no arithmetic behind `.pi` to have rounded — so membership of one list implies membership of the other. Kept separately, the two disagreed on `signalingNaN`.

`bitPattern` is exempt because it is one of the three forms the diagnostic recommends; flagging it would punish the fix.

### Per-line disable

Add `// fp-safety:disable` to any line to suppress all FP diagnostics on that line:

```swift
let totalCents: Double = 1999
let expectedCents: Double = 1999

// This specific comparison is intentional (currency amounts stored as cents)
if totalCents == expectedCents { print("paid in full") }  // fp-safety:disable
```

The marker also covers the line below it when it sits alone on a comment line:

```swift
// fp-safety:disable — currency amounts stored as cents, exact by construction
if totalCents == expectedCents { print("paid in full") }
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
import QualityGateCore

let sourceCode = "let ratio = total / count"
let auditor = FloatingPointSafetyAuditor()
let auditResult = try await auditor.auditSource(
    sourceCode,
    fileName: "MyFile.swift",
    configuration: Configuration()
)
for diagnostic in auditResult.diagnostics {
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
