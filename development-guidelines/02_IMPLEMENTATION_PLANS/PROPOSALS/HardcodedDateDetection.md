# Proposal: Hardcoded Date Detection in TestQualityAuditor

## Problem

Test helper functions that use hardcoded dates as defaults silently break when those dates
age past time-window boundaries in production code. Example:

```swift
private func makeMetadata(timestamp: Date? = nil) -> CheckResultMetadata {
    CheckResultMetadata(
        timestamp: timestamp ?? makeDate("2026-04-28"),  // Will break in 30 days
        ...
    )
}
```

This caused three ConsistencyCheckerTests to fail in CI on 2026-05-28 — exactly 30 days after
the hardcoded date crossed the `ConsistencyChecker`'s 30-day metadata window. The failure was
silent locally because the pre-push hook didn't run tests.

## Solution

Add a `hardcoded-date` rule to the existing `TestQualityAuditor` that flags string literals
in test code matching date patterns (`YYYY-MM-DD`) when those dates are close enough to "now"
to be acting as time proxies rather than fixed test fixtures.

### Detection Logic

**Visit**: `StringLiteralExprSyntax` nodes in test files.

**Match**: Content matching `^\d{4}-\d{2}-\d{2}$` (ISO date format).

**Flag when**: The parsed date is within 365 days of the current date (past or future).
Dates far in the past (e.g., `"2020-01-01"`) are likely intentional fixtures and should not
flag. Dates near the present are likely "meant to be recent" and will drift.

**Severity**: `warning` — the date may be intentional, but the author should confirm.

**Rule ID**: `hardcoded-date`

**Exemption**: `// TEST-QUALITY:` comment on the same or preceding line.

### What It Catches

```swift
// FLAGGED: recent date used as default — will age past time windows
timestamp: timestamp ?? makeDate("2026-04-28"),

// FLAGGED: date within 365 days of now
let recent = makeDate("2026-03-15")

// NOT FLAGGED: distant past date — intentional fixture
let epoch = makeDate("2020-01-01")

// NOT FLAGGED: exempted
// TEST-QUALITY: fixed date for deterministic snapshot test
let snapshot = makeDate("2026-05-01")
```

### Suggested Fix

"Use `Date()` or `Date().addingTimeInterval(...)` for timestamps that represent 'recent'.
Hardcoded dates drift past time windows as the calendar advances."

## Implementation

1. Add `visit(_ node: StringLiteralExprSyntax)` to `TestQualityVisitor`
2. Extract string content, match against ISO date regex
3. Parse matched dates, check if within 365-day window of `Date()`
4. Emit diagnostic with `ruleId: "hardcoded-date"`
5. Add tests: flagged recent date, allowed distant date, exemption, non-date strings

## Scope

- No new targets — extends existing `TestQualityAuditor` and `TestQualityAuditorTests`
- No configuration changes — uses existing exemption mechanism
- ~40 lines of visitor code, ~80 lines of tests
