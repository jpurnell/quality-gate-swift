# ``TestQualityAuditor``

Catches test-quality anti-patterns that compile cleanly but undermine confidence in your test suite.

## Overview

TestQualityAuditor uses SwiftSyntax to walk Swift test files and apply two families of rule, both targeting the ways a test silently stops proving anything. It scans every `.swift` file under `Tests/`, detects `import Testing` and `@Test` attributes, and flags patterns that produce green results without actually validating behavior.

This auditor targets the Swift Testing framework (`#expect`, `#require`, `@Test`). It does not analyze XCTest-based files.

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `exact-double-equality` | error | `#expect(a == 0.3989)` — exact `==`/`!=` on floating-point operands inside an assertion. Same rule as `fp-safety`'s `fp-equality`, at error severity. |
| `force-try-in-test` | error | `try!` anywhere in test code |
| `unseeded-random` | warning | `.random` or `SystemRandomNumberGenerator` producing non-deterministic test data |
| `missing-assertion` | warning | A `@Test` function with no `#expect` or `#require` call |
| `weak-assertion` | warning | `#expect(x != 0)` or `#expect(x != nil)` that checks existence without validating correctness |

### Semantic rules

The rules above are properties of a single assertion's *syntax*: exact, fast, and a finding is a defect. The rules below are **proxies**. No syntactic rule can see the relationship between an assertion and the thing under test, so these name shapes where vacuous tests are found in practice — accepting some false positives in exchange for being cheap and deterministic.

| Rule ID | Severity | Default | What it catches |
|---------|----------|---------|-----------------|
| `unasserted-optional-unwrap` | error | on | `guard let x = f() else { return }` in a `@Test` — when `f()` returns nil the test passes having run no assertions |
| `self-referential-expectation` | error | on | An expected value that restates the body of the function it is testing, so the assertion holds for whatever that body is |
| `non-strict-improvement` | warning | on | `#expect(new <= old)` in a test whose name claims *better*, *improve*, *beat*, *exceed* or *outperform* — an unchanged implementation also passes |
| `skipped-test-inventory` | note | on | Every test that does not run: `.disabled(…)`, `.enabled(if:)`, `XCTSkip`, or an early return gated on the environment |
| `unvaried-parameter` | warning | **opt-in** | One call, all-literal arguments, one assertion — cannot detect that a parameter is ignored |
| `assertion-on-constant` | warning | **opt-in** | `#expect(true)`, `#expect(1.0 == 1.0)` — an assertion that never reaches your code |
| `tolerance-without-magnitude` | warning | **opt-in** | An absolute tolerance exceeding 1% of the magnitude it is measured against |

#### Why three rules are opt-in

Each was measured across a 557-file corpus that passes this checker today, and each arrives with a worklist unrelated to whatever commit first trips over it: `tolerance-without-magnitude` reports 384, `unvaried-parameter` 129, `assertion-on-constant` 73. A rule that is red on arrival gets switched off rather than acted on — the lesson `property-coverage` (69 findings) and `doc-code` (16) both paid for here. Promotion is earned by repairing a corpus, never by relaxing the rule.

Enable them per project:

```yaml
enabledCheckers:
  - test-quality.unvaried-parameter
  - test-quality.assertion-on-constant
  - test-quality.tolerance-without-magnitude
```

#### The inventory never gates

`skipped-test-inventory` reports at `note`, so it appears on every run and never fails a build. This is deliberate: a warning gates under this project's zero-warning bar, and an inventory that blocks every commit in any repository that has ever disabled a test is an inventory nobody keeps. A disabled test's `git blame` age is printed in the diagnostic, best-effort, and never contributes to the verdict or to a cache key — the reasoning is in `SkippedTestAge`. Escalate it if you want it to bite:

```yaml
overrides:
  test-quality.skipped-test-inventory: warning
```

### Configuration

TestQualityAuditor reads the project `Configuration` to determine:

- **`excludePatterns`** -- glob patterns for files to skip (e.g., `**/Fixtures/**`).
- **`safetyExemptions`** -- additional suppression comment patterns beyond the built-in `// TEST-QUALITY:` and `// fp-safety:disable`.

No auditor-specific initializer options are needed. Create with `TestQualityAuditor()` and call `check(configuration:)`.

```swift
import QualityGateCore

let config = Configuration()
let auditor = TestQualityAuditor()
let result = try await auditor.check(configuration: config)
```

For unit testing the auditor itself, `auditSource(_:fileName:configuration:)` accepts a raw source string without touching the filesystem.

### Suppression comments

The five syntactic rules can be suppressed with a bare `// TEST-QUALITY:` comment on the same line or the line immediately above the flagged construct.

The **semantic rules require the marker to name the rule**, because a blanket marker suppresses rules its author never considered. The corpus measurement found 73 lines of `#expect(true) // TEST-QUALITY: <reason>` written to satisfy `missing-assertion` — every one of them precisely what `assertion-on-constant` exists to find. Naming the rule keeps one acknowledgement from silently becoming another:

```swift
import Testing

let fitted = 0.4212      // SSE from the fitted parameters
let gridBest = 0.4212    // SSE from an exhaustive grid search — a tie is legitimate

// TEST-QUALITY: non-strict-improvement — a grid optimum can legitimately tie
#expect(fitted <= gridBest)
```
 `exact-double-equality` also honours `// fp-safety:disable`, which is the canonical marker for that rule in both checkers:

```swift
import Testing

let lookup: [Double] = [1.0, 0.5, 0.25, 0.125]

// fp-safety:disable — table entries are exact by construction
#expect(lookup[3] == 0.125)
```

For an intentional IEEE 754 identity check, write the claim instead of suppressing it — `#expect(result.isEqual(to: 0.0))` is accepted with no marker at all.

Suppressed violations appear in the `overrides` array of the `CheckResult`, not in `diagnostics`, so they are auditable but do not fail the gate.

### Out of scope

- XCTest assertions (`XCTAssertEqual`, `XCTAssertTrue`, etc.)
- Cross-file test helper analysis (a helper that calls `#expect` on behalf of the test function)
- Assertion count thresholds (e.g., requiring more than one assertion per test)
- Test naming conventions or `@Suite` structure
- Performance test validation (`measure` blocks)

## Topics

### Essentials

- ``TestQualityAuditor/check(configuration:)``
- ``TestQualityAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:TestQualityAuditorGuide>
