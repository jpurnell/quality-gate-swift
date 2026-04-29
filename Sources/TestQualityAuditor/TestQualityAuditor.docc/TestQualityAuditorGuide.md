# TestQualityAuditor Guide

A practical walkthrough of every TestQualityAuditor rule, with the bug it catches and the recommended fix.

## Why this auditor exists

A green test suite means nothing if the tests themselves are broken. Five patterns account for the vast majority of silently useless tests:

1. **Floating-point equality with `==`.** IEEE 754 arithmetic means `0.1 + 0.2 != 0.3`. A test that asserts exact equality on a `Double` will either always pass (because the computation happens to be bit-identical today) or always fail after an unrelated refactor changes evaluation order. Neither outcome tests the math.

2. **Force-try in test code.** `try!` crashes the test runner on failure instead of producing a diagnostic. The test appears to pass until the day it doesn't -- and then it takes down the entire suite instead of reporting one failure.

3. **Unseeded randomness.** `.random` and `SystemRandomNumberGenerator` produce different values on every run. A test that depends on random input is non-reproducible: it can pass locally and fail in CI, or vice versa, with no way to replay the failure.

4. **Missing assertions.** A `@Test` function that calls production code but never calls `#expect` or `#require` is a smoke test at best. It proves the code doesn't crash, but it doesn't prove the code is correct.

5. **Weak assertions.** `#expect(result != 0)` proves the result is non-zero but says nothing about whether it's the *right* non-zero value. `#expect(result != nil)` proves something was returned but not what. These patterns survive almost any regression.

TestQualityAuditor catches all five at quality-gate time, before they reach the repository.

## Rule walkthrough

### `exact-double-equality`

Exact `==` on a floating-point literal inside `#expect` is almost always wrong. Floating-point arithmetic is not associative: `(a + b) + c` may differ from `a + (b + c)` by one or more ULPs. The test will break the moment someone refactors the computation order, even if the math is still correct.

```swift
import Testing

@Test func gaussianPDF() {
    let result = gaussian(x: 0.0, mean: 0.0, sigma: 1.0)

    // flagged -- exact equality on Double literal
    #expect(result == 0.3989422804014327)
}
```

The fix is a tolerance comparison. The tolerance should reflect the precision you actually need, not an arbitrary epsilon:

```swift
import Testing

@Test func gaussianPDF() {
    let result = gaussian(x: 0.0, mean: 0.0, sigma: 1.0)

    // accepted -- tolerance-based comparison
    #expect(abs(result - 0.3989422804014327) < 1e-10)
}
```

Integer literals inside `#expect` are not flagged. The rule triggers only when at least one operand is a `FloatLiteralExprSyntax` (contains a decimal point or exponent).

The `!=` operator with a float literal is not flagged by this rule. Only `==` is, because the anti-pattern is asserting bit-identical results from floating-point computation.

### `force-try-in-test`

`try!` in test code is never appropriate. If the expression can throw, the test should either propagate the error (by declaring `throws`) or assert on it (with `#expect(throws:)`). `try!` hides the failure mode and crashes the runner.

```swift
import Testing

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
@Test func loadConfiguration() throws {
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

@Test func createUser() {
    // flagged -- no assertion anywhere in the function body
    let user = User(name: "Alice", age: 30)
    _ = user.formattedName()
}
```

Add assertions that validate the behavior under test:

```swift
import Testing

@Test func createUser() {
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

@Test func calculateRevenue() {
    let revenue = calculateQuarterlyRevenue(units: 100, price: 49.99)

    // flagged -- proves non-zero but not correct
    #expect(revenue != 0)
}
```

Assert the actual expected value or a meaningful bound:

```swift
import Testing

@Test func calculateRevenue() {
    let revenue = calculateQuarterlyRevenue(units: 100, price: 49.99)

    // accepted -- asserts the specific expected result
    #expect(abs(revenue - 4999.0) < 0.01)
}
```

For optionals, unwrap with `#require` and then assert on the value:

```swift
import Testing

@Test func lookupUser() {
    let user = database.findUser(id: 42)

    // flagged -- proves non-nil but not correct
    #expect(user != nil)
}
```

```swift
import Testing

@Test func lookupUser() throws {
    // accepted -- unwrap and assert on the actual value
    let user = try #require(database.findUser(id: 42))
    #expect(user.name == "Alice")
    #expect(user.age == 30)
}
```

The rule fires for both orderings: `#expect(x != 0)` and `#expect(0 != x)` are both flagged, as are `#expect(x != nil)` and `#expect(nil != x)`.

## False positives and how to suppress them

Every rule supports suppression via a `// TEST-QUALITY:` comment on the same line or the line immediately above the flagged statement. The comment must explain why the suppression is appropriate.

### Per-rule suppression examples

**exact-double-equality** -- Legitimate when testing IEEE 754 identity (e.g., verifying that `0.0 / 0.0` produces `NaN`, or that a specific bit pattern round-trips):

```swift
// TEST-QUALITY: verifying IEEE 754 negative-zero identity
#expect(result == -0.0)
```

**force-try-in-test** -- Legitimate when the expression provably cannot throw (e.g., a regex literal known at compile time):

```swift
// TEST-QUALITY: regex literal cannot throw
let pattern = try! Regex("[0-9]+")
```

**unseeded-random** -- Legitimate in statistical distribution tests that validate invariants (e.g., "the mean of 10,000 samples is within 3 sigma of the theoretical mean"):

```swift
// TEST-QUALITY: statistical distribution test; invariant holds regardless of seed
let samples = (0..<10_000).map { _ in Double.random(in: 0...1) }
#expect(abs(samples.mean - 0.5) < 0.05)
```

**missing-assertion** -- Legitimate for pure smoke tests that verify "does not crash" as their contract:

```swift
// TEST-QUALITY: smoke test -- verifies init does not crash under memory pressure
@Test func stressInit() {
    for _ in 0..<1000 {
        _ = HeavyObject(size: 1_000_000)
    }
}
```

**weak-assertion** -- Legitimate when the only contract is non-nil or non-zero (e.g., an ID generator whose specific value is opaque):

```swift
// TEST-QUALITY: UUID generator contract is non-nil; specific value is opaque
#expect(generator.next() != nil)
```

### Suppression mechanics

Suppressed violations are recorded in the `overrides` array of `CheckResult`. They do not fail the quality gate but remain visible in audit reports. This means suppressions are auditable: a reviewer can search for `// TEST-QUALITY:` comments and evaluate whether each justification still holds.

The suppression comment must appear on the flagged line or the line immediately above it. Comments two or more lines above, or below the flagged line, are not recognized. Block comments (`/* */`) are not recognized.

If you find yourself suppressing the same rule across many files, the rule may be miscalibrated for your codebase. Open an issue.
