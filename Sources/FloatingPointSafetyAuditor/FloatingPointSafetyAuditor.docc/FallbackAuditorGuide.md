# A Conversion That Traps

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

## The rule

| Rule ID | What it flags | Severity |
|---------|---------------|----------|
| `fallback.int-conversion-unguarded` | `Int(x)` — or any fixed-width integer type — on a floating-point `x` that nothing before it has shown to be representable | error |

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

## Where the type comes from

SwiftSyntax gives syntax and not types, so the checker reads what is written, in one file, and does not guess:

- a **parameter** — `tenor: Double`
- a **local**, annotated or initialised from a floating-point expression
- a **generic parameter** constrained to `Real`, `BinaryFloatingPoint` or `FloatingPoint`, on the function, the type, or an extension's `where` clause
- a **member or tuple label** — `entry.tenor` — when every declaration of that name in the file agrees on its type

A name with no declaration in reach is skipped. So is a member declared in another file, and a member name declared with two different types in this one.

Three things are floating-point and are still not findings:

- **A literal**, and a `let` initialised from one. `static let deadline: TimeInterval = 30` is thirty at every call.
- **An integer converted upward.** `Int(Double(count) * 0.95)` cannot be NaN.
- **Test code.** A test that feeds a NaN to a conversion to watch it trap is doing its job.

## Reading a clean result

Every run prints what it examined:

```
fallback examined 329 files · 12 integer conversions of a floating-point value, 0 unguarded
```

The middle number is the one to read a pass against. A clean run that examined no conversions has said nothing about a package that performs them on members declared in other files.

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
