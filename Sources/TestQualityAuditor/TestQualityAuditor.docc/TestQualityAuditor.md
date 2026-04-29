# ``TestQualityAuditor``

Catches test-quality anti-patterns that compile cleanly but undermine confidence in your test suite.

## Overview

TestQualityAuditor uses SwiftSyntax to walk Swift test files and apply five rules that target the most common ways tests silently stop proving anything. It scans every `.swift` file under `Tests/`, detects `import Testing` and `@Test` attributes, and flags patterns that produce green results without actually validating behavior.

This auditor targets the Swift Testing framework (`#expect`, `#require`, `@Test`). It does not analyze XCTest-based files.

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `exact-double-equality` | error | `#expect(a == 0.3989)` using exact `==` on a floating-point literal |
| `force-try-in-test` | error | `try!` anywhere in test code |
| `unseeded-random` | warning | `.random` or `SystemRandomNumberGenerator` producing non-deterministic test data |
| `missing-assertion` | warning | A `@Test` function with no `#expect` or `#require` call |
| `weak-assertion` | warning | `#expect(x != 0)` or `#expect(x != nil)` that checks existence without validating correctness |

### Configuration

TestQualityAuditor reads the project `Configuration` to determine:

- **`excludePatterns`** -- glob patterns for files to skip (e.g., `**/Fixtures/**`).
- **`safetyExemptions`** -- additional suppression comment patterns beyond the built-in `// TEST-QUALITY:`.

No auditor-specific initializer options are needed. Create with `TestQualityAuditor()` and call `check(configuration:)`.

```swift
let auditor = TestQualityAuditor()
let result = try await auditor.check(configuration: config)
```

For unit testing the auditor itself, `auditSource(_:fileName:configuration:)` accepts a raw source string without touching the filesystem.

### Suppression comments

Every rule can be suppressed with a `// TEST-QUALITY:` comment on the same line or the line immediately above the flagged construct:

```swift
// TEST-QUALITY: intentional exact comparison for IEEE 754 identity check
#expect(result == 0.0)
```

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
