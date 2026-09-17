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
| `coalesced-assertion` | warning | on | `#expect(abs((ma[k] ?? 0) - 100.0) < 1e-6)` — the assertion fabricates a literal for a value that may be missing, so absence is no longer what fails |
| `ambient-calendar-in-test` | error | on | `Calendar.current` or `Calendar(identifier:)` in a test — the result depends on the locale and time zone of whatever machine runs it |
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

#### One rule was promoted to error and reverted the same day

Both rules shipped 2026-09-14 at `warning`. `ambient-calendar-in-test` is now `error`. `coalesced-assertion` was promoted alongside it on 2026-09-16 and **reverted within the hour**, and the reason is the most useful thing on this page.

Promotion was justified on the five repositories named in the rule's proposal, all of which reported zero. **Five was the wrong denominator.** The corpus knows **78 projects** that push gate telemetry and **75** that run `test-quality`; a query over their most recent runs found **113 findings across 19 projects**, including `SwiftMCPServer` — whose own gate blocked a push within the hour of promotion.

ADR-001 says to measure per consuming repository. The promotion measured a proposal's list, which is a different and much smaller thing. The correction is not "be more careful": the consumer set is **discoverable**, the scan takes about a second against data already in the corpus, and a promotion that does not run it is guessing. Re-promotion is gated on that query returning zero.

What the release bought, in two working days:

- **54 findings became 0**, in every repository by repair rather than suppression. 40 `coalesced-assertion` sites became `try #require` bindings; 14 ambient readings became fixed calendars. Not one line marker and not one file marker was needed.
- **The rules were found wrong 26 times** — 17 `coalesced-assertion` and 9 `ambient-calendar-in-test` — and both carve-out sets below come from that. Had they shipped at `error`, those 26 would have been build failures, and the fix anyone reaches for at that point is the marker, not the carve-out.

Promotion is the recorded end of that process. If a rule of yours is arriving red, this is the shape to copy.

Both were narrowed by a corpus before shipping, which is the only evidence that matters for a proxy rule:

- `coalesced-assertion` ignores a fallback inside a **closure** passed to the assertion. `#expect(diagnostics.contains { ($0.ruleId ?? "").contains("bounded-io") })` is correct — the fallback answers the *predicate*, where "missing means does not match" is the right reading, and the search still fails if nothing matches. Without that carve-out the rule reported fourteen findings on this repository's own suite, every one of them correct code. It also ignores `?? false` unless a `!` encloses it, because `#expect(x?.p() ?? false)` is the canonical spelling of *non-nil and true* and a missing value already fails it.
- `ambient-calendar-in-test` covers `Calendar` and nothing else. `Date()` was in the first draft and was dropped: telling a *timestamp* reading from a *calendar date* reading needs dataflow, and `hardcoded-date`'s suggested fix is literally "Use `Date()`", so the two rules would have pulled against each other on one line. **A timestamp wants `Date()`; a calendar date wants a fixed calendar.** It also spares a `Calendar(identifier:)` whose `timeZone` is pinned by a later statement in the same block — including one inside an `if let`, and one pinned on a `DateComponents` the calendar was assigned into. `Calendar.current` gets no such carve-out: pinning a zone fixes half of it, and the calendar *system* is still the runner's, so the same instant yields a different year under a Japanese or Buddhist locale.

#### What the five repositories actually contain

Measured 2026-09-16 with the shipped binary, which is what the warning release was for:

| Repository | Test files | `coalesced-assertion` | `ambient-calendar-in-test` |
|---|---:|---:|---:|
| BusinessMath | 579 | 4 | 8 |
| BusinessMathPro | 40 | **31** | 5 |
| BusinessMathMarketData | 14 | 3 | 1 |
| businessMathMCP | 26 | 2 | 0 |
| BusinessMathCharts | 6 | 0 | 0 |

Two things in that table decided what happened next. The zone carve-outs above came from it — 9 of the 23 ambient sites were correct code pinning their own zone, and a rule wrong two times in five gets suppressed rather than fixed. And the `coalesced-assertion` column is why promotion to `error` is not on the table yet: 40 findings across four repositories is a worklist, not a gate.

It is also why the rule earns its place. Seven sites in `BusinessMathPro/Risk/PortfolioRiskTests.swift` read `#expect(abs(greeks.gamma[equityId] ?? 0.0) < 1e-10)` — asserting a Greek is zero, in a form that passes just as happily when the Greek was never computed at all. Those are tests that stopped testing, and nothing else found them.

#### A file whose subject is the flagged shape

A suite that exists to prove behaviour across time zones reads the ambient calendar in every test it contains, on purpose. Repeating a line marker on forty sites is the noise that gets a rule switched off, and `excludePatterns` is too blunt — it would hide every other test-quality rule in the same file, including the ones that would find a real defect there. State the marker once, for the file:

```swift
// TEST-QUALITY-FILE: ambient-calendar-in-test — this suite's subject is time-zone behaviour
```

It still has to name the rule, so it cannot silence one its author never considered, and it still records an override **per suppressed site**, so the count stays visible in the report instead of collapsing to one. It applies only to the semantic rules, never to the five syntactic ones.

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

The **semantic rules require the marker to name the rule** — on the flagged line or the one above it, or once for the whole file as `// TEST-QUALITY-FILE: <rule-id> — <reason>` — because a blanket marker suppresses rules its author never considered. The corpus measurement found 73 lines of `#expect(true) // TEST-QUALITY: <reason>` written to satisfy `missing-assertion` — every one of them precisely what `assertion-on-constant` exists to find. Naming the rule keeps one acknowledgement from silently becoming another:

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
