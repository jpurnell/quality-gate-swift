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
| `fallback.guard-returns-a-value` | A guard against zero that a NaN fails, answering with a value nothing documents | note |
| `fallback.justification-empty` | `// fallback-justified:` with no reason after it | warning |

The first three are findings. The fourth is a question, and never fails a run.

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

**Membership of a constant range, asserted by a `guard`.** `(1.0..<1e10).contains(x)` has always counted. So does the same test against a name, when the name is a `let` whose value is a range between two numeric literals — in this file, or as `Type.member` anywhere in the project:

```swift
enum DegreesOfFreedom {
    static let allowed: Range<Double> = 1..<1e10
}

func wholeDegrees(_ df: Double) -> Int? {
    guard DegreesOfFreedom.allowed.contains(df) else { return nil }
    return Int(df.rounded(.towardZero))
}
```

A `var`, a range with an open or infinite end, a range computed from anything but literals, and a name that is also declared as something else anywhere it could be confused with — a parameter called `allowed`, a `Set` called `allowed` in another type — are not accepted. `allowed.contains(x)` on a set bounds nothing.

A *local* constant — `let allowed = -90.0...90.0` inside a function — bounds a value tested against it in that function, after it is declared, and nowhere else. A member called `allowed` used bare in another function is not that local.

### A bound carried through a local

A value is usually checked under one name and converted under another. The conversion is accepted when the arithmetic between the two keeps the value a number inside a range:

```swift
func lowerRank(of k: Double, among count: Int) -> Int? {
    guard k >= 0, k <= 1 else { return nil }
    let rank = k * Double(count - 1)
    return Int(rank.rounded(.down))
}

func clampedRank(of p: Double, among count: Int) -> Int? {
    guard !p.isNaN else { return nil }
    let clamped = Swift.min(Swift.max(p, 0), 1)
    return Int(clamped * Double(count - 1))
}
```

What is followed is a `let` declared once in the body. What keeps a bound:

- **A sum, a difference or a product** whose every operand is bounded — a guarded value, a literal, an integer converted upward.
- **Division by a literal** other than zero. Any other quotient is a new source of NaN, and keeps nothing.
- **Rounding, `abs` and `magnitude`.**
- **`min` and `max`**, read with the fact that makes them treacherous: each returns its *first* argument when either is a NaN. So `min(x, 1)` has an upper bound whatever `x` is, and is a number only if `x` is. `max(0, min(100, x))` is bounded even for a NaN — it answers `100`, which is the clamp rule's finding, not this one's.
- **A remainder by a literal**, `x.truncatingRemainder(dividingBy: 100)`, when `x` was tested with `isFinite`. The remainder of an infinity is a NaN.

A bound learned this way joins an `isFinite` learned from a guard. `min(span / scale, 1.0)` is at most one and, with `span` and `scale` both guarded above zero, at least zero — if it is a number at all, which a quotient may not be. `guard fraction.isFinite` on the local it is bound to supplies the rest.

`min(x, .infinity)` and `min(x, .greatestFiniteMagnitude)` bound nothing an `Int` can hold. A `var` is not followed: it is something else by the time it is read.

### A bound asserted by the arm the conversion sits in

`position >= 0 && position < 4_096 ? Int(position) : 0` converts only when the comparison held, and so does the body of `if position >= 0, position < 4_096 { … }`. The condition speaks for its own arm: in the `else`, and in the third operand of a ternary, the comparison was false, which is what every comparison with a NaN is. It does not speak across a closure, which may run later, or for a value the arm writes to before converting it — `if x < limit { x = raw; return Int(x) }` is reported.

### What does not count

**`isFinite` alone.** `1e300` is finite, and `Int(1e300)` traps.

**One bound.** `guard x < limit` leaves `-1e300`.

**A guard joined with `||`.** It holds when either side does, so it asserts neither.

**A check after the conversion, or in another function.**

**A filter upstream on a member.** `rates.filter { $0.tenor.isFinite }` followed by a loop that converts `entry.tenor` is invisible to a syntactic check. The rule asks for the check in the function that converts, where a reader of the conversion can see it. (A collection of plain values tested whole *is* read — see *A collection tested whole*, below — but `isFinite` on every element is still only `isFinite`, and a conversion needs a bound.)

**A check in a function that is called.** A private helper that returns only bounded values, or an initialiser that refuses an unbounded one, is not followed. The rule reads one body at a time.

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

So does a guard on a value *computed from* the operand by arithmetic. A NaN in either bound makes the span a NaN, and the guard that let the span through has refused both:

```swift
func coordinate(of parameter: Double, lower: Double, upper: Double) -> Double {
    let span = upper - lower
    guard span > 0 else { return 0 }
    let clamped = Swift.min(Swift.max(parameter, lower), upper)
    return (clamped - lower) / span
}
```

That holds only while the arithmetic carries a NaN: sums, differences, products, quotients, negation and rounding do. A local built with `min`, `max`, a ternary or `??` may have swallowed one, and a guard on it proves nothing about what went in. `guard span != 0` proves nothing either — a NaN is unequal to everything.

### A collection tested whole

`guard values.allSatisfy({ $0.isFinite })` — or `{ !$0.isNaN }`, or `\.isFinite` — answers for every element read afterwards by `for value in values`, by `values.enumerated()` or by subscript. So does a filtered copy, `let clean = values.filter { $0.isFinite }`. The test has to be asserted by a `guard`, on the collection that is then read, before it is read.

It answers for the collection that was tested, and for as long as that is what the name holds. A collection in a local `var` is not covered — it may have been appended to or replaced since — and a loop's element is covered inside that loop's body only: a later `for value in others` reusing the name is a loop over something nothing tested.

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

Two shapes are accepted because nothing in them answers *for* the NaN.

**A trailing `else` that hands the value on.** If the `else` is one statement that returns or assigns the value itself, or arithmetic on it, a NaN that lands there leaves as a NaN:

```swift
func unitInterval(_ p: Double) -> Double {
    if p < 0 {
        return 0
    } else if p > 1 {
        return 1
    } else {
        return p
    }
}
```

`else { return 0.5 }` answers for it and is reported. So is `else { return min(1, p) }`, which can swallow it, any chain with no `else` at all, and an `else` of more than one statement — with anything before the last, the name may no longer be the value that was classified.

**A chain inside `if x.isInfinite { … }`.** There the value is one of two infinities, and both compare. The `else` of that `if` is not the same place: a NaN is not infinite, and arrives there.

## A guard that answers

```swift
func excessKurtosis(fourthMoment: Double, deviation: Double) -> Double {
    guard deviation > 0 else { return 0 }
    return fourthMoment / (deviation * deviation * deviation * deviation) - 3
}
```

The guard is correct about zero. It is also what runs for a NaN, which is not greater than anything — and then `0` is reported as the excess kurtosis of data that was never measured, which reads as *exactly normal-tailed*.

Whether `0` is the right answer is not something a checker can know. In one function of the campaign that prompted this rule, two guards four lines apart read the same; zero assets really is distress, and zero liabilities is the safest balance sheet there is. So this is reported at `note`, as a question, and it is answered once, in one of three ways.

**Say so where the caller reads it.** A `- Returns:` clause that names the value as what is returned in some case is a contract, and the finding goes away:

```swift
/// The share of a total.
///
/// - Returns: The proportion, or 0 if there is no total.
func share(of part: Double, in total: Double) -> Double {
    guard total > 0 else { return 0 }
    return part / total
}
```

The clause has to hold the value as a word of its own — `0`, `0.0` and `zero` are one value — *and* a word that makes the sentence conditional: `if`, `when`, `whenever`, `unless`, `otherwise`. "A proportion from 0 to 1" has the first and not the second; it describes a range. A property has no Returns clause, so its whole comment is read.

**Refuse.** `nil`, `throw`, `.nan` and `.infinity` are not answers, and a guard that returns one is not reported. Nor is a guard that returns something computed.

**Record the decision.** `// fallback-justified: <reason>` on the line directly above the guard. The finding is recorded as an override rather than dropped, so the justifications in a package can be read as a list, and the coverage note counts them. The reason is required.

A justification is the weakest of the three, because it is addressed to the checker and the caller never sees it. A comment that is true about zero and silent about NaN is also exactly what this rule exists to find.

### What is read as this shape

- The guard compares against zero, or a threshold written in its place: `0`, `T(0)`, `.zero`, `.ulpOfOne`. `guard x >= lower, x <= upper` states a domain and is not reported.
- The comparison is ordered. `guard total != 0` lets a NaN through, since a NaN is unequal to everything, so its fallback is not given for one.
- The value compared could be a NaN. An integer, or a `let` converted from one, could not.
- Nothing above the guard has already refused a NaN.

A name with no type of its own takes one from what it is compared with: `s > T(0)` does not compile unless `s` is a `T`. A bare `0` is no such evidence.

## Where the type comes from

SwiftSyntax gives syntax and not types, so the checker reads what is written, in one file, and does not guess:

- a **parameter** — `tenor: Double`
- a **local**, annotated or initialised from a floating-point expression
- a **generic parameter** constrained to `Real`, `BinaryFloatingPoint` or `FloatingPoint`, on the function, the type, or an extension's `where` clause
- a **member or tuple label** — `entry.tenor` — when every declaration of that name in the file agrees on its type
- an **element** of a floating-point collection, read by subscript, by `for … in`, or out of `enumerated()`
- a **sum** from `reduce` with a floating-point seed

A call written with its module — `Swift.min(a, b)`, `Swift.abs(x)`, `Foundation.floor(x)` — is the bare call, and carries a NaN exactly as it does.

A name with no declaration in reach is skipped. So is a member declared in another file, and a member name declared with two different types in this one. A member name the standard library owns — `count`, `startIndex` — is never read from the file's own declarations: a type that declares `count: Double` has said nothing about `values.count`.

### Floating-point is not the same as able to be NaN

`let n = Double(count)` is floating-point and is a number. The rules keep the two apart, and report only values that could be a NaN:

- **A literal**, and a `let` initialised from one. `static let deadline: TimeInterval = 30` is thirty at every call.
- **An integer converted upward**, and sums and products of those. `Int(Double(count) * 0.95)` cannot be NaN.
- **A `let` computed from values like that**, through as many steps as it takes.
- **A constant built from literals.** `static let pageSize = CGSize(width: 612, height: 792)` makes `pageSize.width` a number, and dividing by `Config.pollInterval` is not a new source of NaN when every declaration of `pollInterval` in the file is a `let` holding a literal other than zero.

A `var` is only what it is declared to be, because it is something else by the time it is read. And once one operand of an expression is known to be floating-point, an operand nothing is known about is a floating-point value of unknown origin — which is reported, because unknown origin is not the same as a number.

Test code is not audited. A test that feeds a NaN to a conversion to watch it trap is doing its job.

## Which files are read

In a package, only files a target may compile. A reference script under `project/`, an example kept beside the documentation, a Markdown code fence saved with a `.swift` extension: none is built, and a finding in one can only be answered by moving the file. They are counted, and the coverage note says how many:

```
… 0 justified · 11 .swift files outside any SwiftPM target not audited
```

The scope errs towards reading. A file is left out only when `Package.swift` positively shows no target can own it:

- **No `Package.swift`** — an Xcode project, a directory of scripts — and every file is read, as before.
- **`Sources`, `Source`, `src`, `srcs`, `Tests` and `Plugins`** are read whole, whatever targets the manifest names inside them.
- **A target's explicit `path:`** is read wherever it points.
- **A directory holding an `.xcodeproj` or `.xcworkspace`** is read whole: its files may belong to an Xcode target the manifest knows nothing about.
- **A manifest that cannot be read to a list of directories** — a target whose `path:` is computed, or one rooted at the package directory or outside it — and every file is read. The note then says `target paths in Package.swift could not be read, so every file was audited`, so that a package whose scripts are still being reported knows why.

The manifest is parsed as text. Nothing is resolved and nothing is run. Every target declaration in it is read, wherever it is written, so a manifest that builds its `targets` in a variable and appends to it is read as well as one that passes an array literal.

This is `fallback`'s scope alone. The other checkers read what they read before.

## Reading a clean result

Every run prints what it examined:

```
fallback examined 685 files · 49 integer conversions of a floating-point value, 44 unguarded · 38 clamps, 11 absorbing a NaN · 19 classifications, 15 with no arm for one · 152 guards answering with a value, 110 undeclared, 0 justified
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
