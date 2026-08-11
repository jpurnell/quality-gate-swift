# TestQualityAuditor Guide

A practical walkthrough of every TestQualityAuditor rule, with the bug it catches and the recommended fix.

## Why this auditor exists

A green test suite means nothing if the tests themselves are broken. Five patterns account for the vast majority of silently useless tests:

1. **Floating-point equality with `==`.** IEEE 754 arithmetic means `0.1 + 0.2 != 0.3`. A test that asserts exact equality on a `Double` will either always pass (because the computation happens to be bit-identical today) or always fail after an unrelated refactor changes evaluation order. Neither outcome tests the math. Note that `==` is sometimes exactly right here — see the rule below, which names the three different claims it can be making rather than assuming one.

2. **Force-try in test code.** `try!` crashes the test runner on failure instead of producing a diagnostic. The test appears to pass until the day it doesn't -- and then it takes down the entire suite instead of reporting one failure.

3. **Unseeded randomness.** `.random` and `SystemRandomNumberGenerator` produce different values on every run. A test that depends on random input is non-reproducible: it can pass locally and fail in CI, or vice versa, with no way to replay the failure.

4. **Missing assertions.** A `@Test` function that calls production code but never calls `#expect` or `#require` is a smoke test at best. It proves the code doesn't crash, but it doesn't prove the code is correct.

5. **Weak assertions.** `#expect(result != 0)` proves the result is non-zero but says nothing about whether it's the *right* non-zero value. `#expect(result != nil)` proves something was returned but not what. These patterns survive almost any regression.

TestQualityAuditor catches all five at quality-gate time, before they reach the repository.

## Rule walkthrough

### `exact-double-equality`

Exact `==` or `!=` on floating-point operands inside `#expect` is ambiguous, and usually wrong. Floating-point arithmetic is not associative: `(a + b) + c` may differ from `a + (b + c)` by one or more ULPs, so a test asserting exact equality breaks the moment someone refactors the computation order, even though the math is still correct. It fires on a literal operand *and* on a comparison of two computed `Double`s with no literal anywhere.

```swift
import Testing

func gaussian(x: Double, mean: Double, sigma: Double) -> Double {
    guard sigma > 0 else { return 0 }
    let z = (x - mean) / sigma
    return exp(-0.5 * z * z) / (sigma * (2 * Double.pi).squareRoot())
}

@Test func gaussianPDF() {
    let result = gaussian(x: 0.0, mean: 0.0, sigma: 1.0)

    // flagged -- exact equality on Double literal
    #expect(result == 0.3989422804014327)
}
```

There is no single fix, and the checker does not pretend otherwise. Three genuinely different claims hide under `==` on floating point, and the tolerance form is only one of them:

| the claim | write it as | why the others are wrong |
|---|---|---|
| computed values, rounding expected | `abs(a - b) < epsilon` | an exact form fails on rounding |
| IEEE 754 equality, chosen deliberately | `a.isEqual(to: b)` | a bit-pattern comparison splits `+0.0` from `-0.0` |
| bit-identical results | `a.bitPattern == b.bitPattern` | `==` says `NaN != NaN`, so a reproducibility check with a NaN in the stream passes silently |

```swift
import Testing

@Test func gaussianPDFWithinTolerance() {
    let result = gaussian(x: 0.0, mean: 0.0, sigma: 1.0)

    // accepted -- the tolerance reflects the precision actually needed
    #expect(abs(result - 0.3989422804014327) < 1e-10)
}

@Test func boxMullerDegenerateCase() {
    let radius = (-2 * log(1.0)).squareRoot()
    let z1 = radius * cos(0.0)
    let z2 = radius * sin(0.0)

    // accepted -- sqrt(-2 * log(1)) is -0.0, and IEEE equality is what is
    // meant here. A bit-pattern check would fail on the sign of zero.
    #expect(z1.isEqual(to: 0.0) && z2.isEqual(to: 0.0))
}

@Test func seededRunIsReproducible() {
    let first = gaussian(x: 0.25, mean: 0.0, sigma: 1.0)
    let second = gaussian(x: 0.25, mean: 0.0, sigma: 1.0)

    // accepted -- bit-identity, and NaN-safe, which `==` would not be
    #expect(first.bitPattern == second.bitPattern)
}
```

Reaching for the tolerance form reflexively weakens the second and third cases. The resolution is always a *named comparison*, never another suppression marker: the name lives in the code and cannot drift from it, whereas a marker asserts an intent that can be wrong forever.

Integer comparisons are not flagged, even when a `Double`-typed variable is involved in producing the operands. Comparisons against the sentinels (`0.0`, `.zero`, `.nan`, `.infinity`, `.pi`, `.ulpOfOne`) are not flagged either — exact comparison against those is intentional.

### Where this rule is implemented

`exact-double-equality` is the same rule as `fp-safety`'s `fp-equality`, reported at error severity instead of warning, and only inside an assertion. Detection is shared — see `FloatingPointRules` (FloatingPointSafetyAuditor) — so the two checkers cannot drift apart on which comparisons count, and a suppression marker honoured by one is honoured by the other. They were once two implementations and did drift, on all three counts.

### `force-try-in-test`

`try!` in test code is never appropriate. If the expression can throw, the test should either propagate the error (by declaring `throws`) or assert on it (with `#expect(throws:)`). `try!` hides the failure mode and crashes the runner.

```swift
import Testing

enum ConfigError: Error, Equatable {
    case fileNotFound
}

struct Configuration {
    let timeout: Int

    static func load(from path: String) throws -> Configuration {
        guard path == "test.json" else { throw ConfigError.fileNotFound }
        return Configuration(timeout: 30)
    }
}

@Test func loadConfiguration() {
    // flagged -- try! crashes the runner instead of failing the test
    let config = try! Configuration.load(from: "test.json")
    #expect(config.timeout == 30)
}
```

There are two correct alternatives depending on intent:

```swift
import Testing

// Alternative 1: propagate -- test fails with a clear thrown-error diagnostic
@Test func loadConfigurationPropagates() throws {
    let config = try Configuration.load(from: "test.json")
    #expect(config.timeout == 30)
}

// Alternative 2: assert on the error type
@Test func loadConfigurationMissing() {
    #expect(throws: ConfigError.fileNotFound) {
        try Configuration.load(from: "nonexistent.json")
    }
}
```

This rule fires at error severity because `try!` in tests is a test-infrastructure bug, not a style preference.

### `unseeded-random`

Tests must be deterministic. When a test uses `.random` or `SystemRandomNumberGenerator`, the test input changes on every run. A failure cannot be reproduced without knowing the seed, and CI failures become non-actionable.

```swift
import Testing

@Test func sortHandlesRandomInput() {
    // flagged -- .random produces non-deterministic input
    let values = (0..<100).map { _ in Int.random(in: 0...1000) }
    let sorted = values.sorted()
    #expect(sorted == values.sorted())
}
```

The fix is to inject a seeded generator or use fixed test data:

```swift
import Testing

func mySort(_ values: [Int]) -> [Int] {
    values.sorted()
}

@Test func sortHandlesVariedInput() {
    // accepted -- deterministic test data
    let values = [42, 7, 99, 1, 55, 23, 88, 3, 67, 14]
    let sorted = mySort(values)
    #expect(sorted == [1, 3, 7, 14, 23, 42, 55, 67, 88, 99])
}
```

If your test genuinely needs randomized input (property-based testing, fuzz testing), use a seeded generator and log the seed so failures are reproducible:

```swift
import Testing

struct SomeSeedableRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Test func sortIsIdempotent() {
    // accepted -- seeded generator is deterministic
    var generator = SomeSeedableRNG(seed: 12345)
    let values = (0..<100).map { _ in Int.random(in: 0...1000, using: &generator) }
    let sorted = mySort(values)
    #expect(mySort(sorted) == sorted)
}
```

The rule also flags `SystemRandomNumberGenerator` by name, since instantiating it directly is equivalent to calling `.random` without a seed.

```swift
import Testing

@Test func generatorUsage() {
    // flagged -- SystemRandomNumberGenerator is unseeded
    var rng = SystemRandomNumberGenerator()
    let value = Int.random(in: 1...100, using: &rng)
    #expect(value >= 1)
}
```

### `missing-assertion`

A `@Test` function that never calls `#expect` or `#require` does not test anything. It may exercise code paths (proving they don't crash), but it cannot detect regressions.

```swift
import Testing

struct User {
    let name: String
    let age: Int

    var isValid: Bool { !name.isEmpty && age >= 0 }

    func formattedName() -> String { "\(name) (\(age))" }
}

@Test func createUser() {
    // flagged -- no assertion anywhere in the function body
    let user = User(name: "Alice", age: 30)
    _ = user.formattedName()
}
```

Add assertions that validate the behavior under test:

```swift
import Testing

@Test func createUserWithAssertions() {
    let user = User(name: "Alice", age: 30)

    // accepted -- explicit behavioral assertions
    #expect(user.formattedName() == "Alice (30)")
    #expect(user.isValid)
}
```

The rule detects `#expect` and `#require` at any nesting depth inside the function body, including inside `do`/`catch` blocks, closures, and conditional branches. A single assertion anywhere in the function satisfies the rule.

Helper functions that call `#expect` on behalf of the test do NOT satisfy the rule, because the auditor is intra-file and does not trace calls across functions. If your test delegates all assertions to a shared helper, add at least one `#expect` in the test body itself, or suppress with `// TEST-QUALITY:`.

### `weak-assertion`

`!= 0` and `!= nil` are the weakest possible assertions. They prove existence but not correctness. A function that returns the wrong value will still pass `#expect(result != 0)` as long as it returns *something*.

```swift
import Testing

func calculateQuarterlyRevenue(units: Int, price: Double) -> Double {
    Double(units) * price
}

@Test func calculateRevenue() {
    let revenue = calculateQuarterlyRevenue(units: 100, price: 49.99)

    // flagged -- proves non-zero but not correct
    #expect(revenue != 0)
}
```

Assert the actual expected value or a meaningful bound:

```swift
import Testing

@Test func calculateRevenueWithinTolerance() {
    let revenue = calculateQuarterlyRevenue(units: 100, price: 49.99)

    // accepted -- asserts the specific expected result
    #expect(abs(revenue - 4999.0) < 0.01)
}
```

For optionals, unwrap with `#require` and then assert on the value:

```swift
import Testing

struct UserDatabase {
    let users: [Int: User]

    func findUser(id: Int) -> User? { users[id] }
}

let database = UserDatabase(users: [42: User(name: "Alice", age: 30)])

@Test func lookupUser() {
    let user = database.findUser(id: 42)

    // flagged -- proves non-nil but not correct
    #expect(user != nil)
}
```

```swift
import Testing

@Test func lookupUserUnwrapped() throws {
    // accepted -- unwrap and assert on the actual value
    let user = try #require(database.findUser(id: 42))
    #expect(user.name == "Alice")
    #expect(user.age == 30)
}
```

The rule fires for both orderings: `#expect(x != 0)` and `#expect(0 != x)` are both flagged, as are `#expect(x != nil)` and `#expect(nil != x)`.

## False positives and how to suppress them

Every rule supports suppression via a `// TEST-QUALITY:` comment on the same line or the line immediately above the flagged statement. The comment must explain why the suppression is appropriate.

`exact-double-equality` additionally honours `// fp-safety:disable`, and `fp-safety` honours `// TEST-QUALITY:`. The two are one marker set for one rule; either checker accepts either marker. `// fp-safety:disable` is the one to reach for in new code — it names the rule rather than a checker.

### Per-rule suppression examples

**exact-double-equality** -- Prefer rewriting the comparison to say what it means (`a.isEqual(to: b)` for IEEE identity, `a.bitPattern == b.bitPattern` for bit identity). Both are accepted without a marker, and unlike a marker they cannot drift from the code. Suppress only where neither form applies:

```swift
let lookup: [Double] = [1.0, 0.5, 0.25, 0.125]

// fp-safety:disable — comparing table entries that are exact by construction
#expect(lookup[3] == 0.125)
```

**force-try-in-test** -- Legitimate when the expression provably cannot throw (e.g., a regex literal known at compile time):

```swift
// TEST-QUALITY: regex literal cannot throw
let pattern = try! Regex("[0-9]+")
```

**unseeded-random** -- Legitimate in statistical distribution tests that validate invariants (e.g., "the mean of 10,000 samples is within 3 sigma of the theoretical mean"):

```swift
extension Array where Element == Double {
    var mean: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}

// TEST-QUALITY: statistical distribution test; invariant holds regardless of seed
let samples = (0..<10_000).map { _ in Double.random(in: 0...1) }
#expect(abs(samples.mean - 0.5) < 0.05)
```

**missing-assertion** -- Legitimate for pure smoke tests that verify "does not crash" as their contract:

```swift
final class HeavyObject {
    let storage: [UInt8]

    init(size: Int) {
        storage = [UInt8](repeating: 0, count: size)
    }
}

// TEST-QUALITY: smoke test -- verifies init does not crash under memory pressure
@Test func stressInit() {
    for _ in 0..<1000 {
        _ = HeavyObject(size: 1_000_000)
    }
}
```

**weak-assertion** -- Legitimate when the only contract is non-nil or non-zero (e.g., an ID generator whose specific value is opaque):

```swift
struct IdentifierGenerator {
    func next() -> String? { UUID().uuidString }
}

let generator = IdentifierGenerator()

// TEST-QUALITY: UUID generator contract is non-nil; specific value is opaque
#expect(generator.next() != nil)
```

### Suppression mechanics

Suppressed violations are recorded in the `overrides` array of `CheckResult`. They do not fail the quality gate but remain visible in audit reports. This means suppressions are auditable: a reviewer can search for `// TEST-QUALITY:` comments and evaluate whether each justification still holds.

The suppression comment must appear on the flagged line or the line immediately above it. Comments two or more lines above, or below the flagged line, are not recognized. Block comments (`/* */`) are not recognized.

If you find yourself suppressing the same rule across many files, the rule may be miscalibrated for your codebase. Open an issue.
