# A Value That Is Not a Number

What `fallback` finds, what it accepts, and what it cannot see.

## Overview

`fp-safety` asks whether a divisor is guarded. ``FallbackAuditor`` asks what becomes of a value that is not a number once it is already in the program.

A NaN is never raised. It is carried, and every comparison with it answers *no*. Most of the time that produces a wrong answer quietly. In one place it stops the process:

```swift
import Foundation

func yearOfUnchecked(tenor: Double) -> Int {
    Int(tenor)   // traps on .nan, on .infinity, and on 1e300
}
```

`Int(_:)` on a floating-point value has no failure path. A value it cannot represent is a runtime trap, and the trap takes every other piece of work in the process with it.

In two more it produces an answer, which is worse, because an answer gets used:

```swift
func concordance(w: Double) -> Double {
    max(0.0, min(1.0, w))        // 1.0 for a NaN: perfect agreement
}

func direction(of slope: Double) -> String {
    if slope > 0 {
        return "upward"
    } else if slope < 0 {
        return "downward"
    } else {
        return "flat"            // and for a NaN
    }
}
```

## The rules

| Rule ID | What it flags | Severity |
|---------|---------------|----------|
| `fallback.int-conversion-unguarded` | `Int(x)` — or any fixed-width integer type — on a floating-point `x` that nothing before it has shown to be representable | error |
| `fallback.clamp-absorbs-nan` | A nested `min` / `max` that returns one of its bounds for a NaN | warning |
| `fallback.classification-omits-nan` | An `if` / `else if` chain that sorts one value by comparison and has no arm for a NaN | warning |

## An integer conversion

### What counts as guarded

**A bound on the magnitude, asserted by a `guard`.** A guard proceeds only when every condition is true, and no comparison with a NaN is true, so a bound written there excludes a NaN without naming it:

```swift
func yearOfBounded(tenor: Double) -> Int {
    guard abs(tenor) < 1e15 else { return 0 }
    return Int(tenor)
}

func wholeShape(shape: Double) -> Int? {
    guard shape > 0, shape <= 1_000_000 else { return nil }
    return Int(shape)
}
```

**A bound written anywhere, together with `isFinite`.** A comparison that is stored, negated or tested in an `if` asserts nothing about the code after it, so it needs the finiteness test beside it:

```swift
func bucket(of position: Double) -> Int {
    let inRange = position >= 0 && position < 4_096
    guard position.isFinite, inRange else { return 0 }
    return Int(position)
}
```

**`Int(exactly:)`, always.** It returns `nil` instead of trapping. It is not a drop-in for truncation — `Int(exactly: 2.5)` is `nil` — so round first:

```swift
func yearOfExact(tenor: Double) -> Int? {
    Int(exactly: tenor.rounded(.towardZero))
}
```

The check may be on an alias of the value. `let sizable = Double(budget)` followed by a guard on `sizable` covers a later `Int(budget)`.

### What does not count

**`isFinite` alone.** `1e300` is finite, and `Int(1e300)` traps.

**One bound.** `guard x < limit` leaves `-1e300`.

**A guard joined with `||`.** It holds when either side does, so it asserts neither.

**A check after the conversion, or in another function.**

**A filter upstream.** `rates.filter { $0.tenor.isFinite }` followed by a loop that converts `entry.tenor` is invisible to a syntactic check. The rule asks for the check in the function that converts, where a reader of the conversion can see it.

## A clamp

`Swift.min` and `Swift.max` are each a comparison and a choice, and they return their **first** argument whenever either is a NaN. A clamp is two of them, so where the NaN ends up depends on where the value was written:

| written as | for a NaN, returns |
|---|---|
| `max(lower, min(upper, x))` | `upper` |
| `max(lower, min(x, upper))` | `lower` |
| `max(min(upper, x), lower)` | `upper` |
| `min(upper, max(lower, x))` | `lower` |
| `min(upper, max(x, lower))` | `upper` |
| `min(max(lower, x), upper)` | `lower` |
| `max(min(x, upper), lower)` | NaN |
| `min(max(x, lower), upper)` | NaN |

Six of the eight absorb it. The two that do not are accepted, though nothing about their spelling tells the next reader that the order matters. The rule is satisfied by asking the question before clamping:

```swift
func concordanceChecked(w: Double) -> Double {
    guard !w.isNaN else { return .nan }
    return max(0.0, min(1.0, w))
}
```

An `isNaN` or `isFinite` test before the clamp answers it, in either sense. So does any comparison that a `guard` asserts.

**A quotient is its own source.** `0 / 0` is a NaN and both operands were finite, so a check on the operands of a division says nothing about its result. A quotient written inside a clamp is reported until it is bound to a local and that local is tested. Dividing by a literal other than zero, or by a value already tested against zero, is not a new source.

## A classification

The rule reads an `if` / `else if` chain in which every arm is one ordered comparison of the same value. A NaN passes none of them.

With a trailing `else`, it takes the `else` — which reads as the case that is left, and is not. Without one it takes no arm at all, which is how a cash flow that could not be evaluated was dropped from a valuation that was then reported as complete:

```swift
func presentValues(of cashFlows: [Double]) -> (inflows: Double, outflows: Double) {
    var inflows = 0.0
    var outflows = 0.0
    for flow in cashFlows {
        if flow > 0 {
            inflows += flow
        } else if flow < 0 {
            outflows += flow
        }
    }
    return (inflows, outflows)
}
```

An arm that tests `isNaN` or `isFinite` answers it, as does a test above the chain. One comparison with an `else` is a test and not a classification, and is not reported. Nor is a chain whose arms test different values.

## Where the type comes from

SwiftSyntax gives syntax and not types, so the checker reads what is written, in one file, and does not guess:

- a **parameter** — `tenor: Double`
- a **local**, annotated or initialised from a floating-point expression
- a **generic parameter** constrained to `Real`, `BinaryFloatingPoint` or `FloatingPoint`, on the function, the type, or an extension's `where` clause
- a **member or tuple label** — `entry.tenor` — when every declaration of that name in the file agrees on its type
- an **element** of a floating-point collection, read by subscript, by `for … in`, or out of `enumerated()`
- a **sum** from `reduce` with a floating-point seed

A name with no declaration in reach is skipped. So is a member declared in another file, and a member name declared with two different types in this one. A member name the standard library owns — `count`, `startIndex` — is never read from the file's own declarations: a type that declares `count: Double` has said nothing about `values.count`.

### Floating-point is not the same as able to be NaN

`let n = Double(count)` is floating-point and is a number. The rules keep the two apart, and report only values that could be a NaN:

- **A literal**, and a `let` initialised from one. `static let deadline: TimeInterval = 30` is thirty at every call.
- **An integer converted upward**, and sums and products of those. `Int(Double(count) * 0.95)` cannot be NaN.
- **A `let` computed from values like that**, through as many steps as it takes.

A `var` is only what it is declared to be, because it is something else by the time it is read. And once one operand of an expression is known to be floating-point, an operand nothing is known about is a floating-point value of unknown origin — which is reported, because unknown origin is not the same as a number.

Test code is not audited. A test that feeds a NaN to a conversion to watch it trap is doing its job.

## Reading a clean result

Every run prints what it examined:

```
fallback examined 685 files · 49 integer conversions of a floating-point value, 44 unguarded · 37 clamps, 11 absorbing a NaN · 19 classifications, 15 with no arm for one
```

The first number of each pair is the one to read a pass against. A clean run that examined nothing has said nothing about a package whose values are members declared in other files.

## Running it

```bash
quality-gate --check fallback
```

```swift
import QualityGateCore

let fallbackSource = "func year(tenor: Double) -> Int { Int(tenor) }"
let fallbackResult = try await FallbackAuditor().auditSource(
    fallbackSource,
    fileName: "Sources/Curves/DiscountCurve.swift",
    configuration: Configuration()
)
for diagnostic in fallbackResult.diagnostics {
    print("\(diagnostic.filePath ?? ""):\(diagnostic.lineNumber ?? 0): \(diagnostic.message)")
}
```
