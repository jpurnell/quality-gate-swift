# ``TestRunner``

Executes `swift test` and parses test failures into structured diagnostics.

## Overview

TestRunner executes your test suite and extracts structured information about any failures. It supports both the new Swift Testing framework and legacy XCTest output formats.

### Supported Output Formats

**Swift Testing** (Swift 6+):
```
Test "My test" recorded an issue at MyTests.swift:42:9: Expectation failed: (actual → 5) == 10
```

**XCTest** (Legacy):
```
/path/to/MyTests.swift:42: error: -[MyTests testSomething] : XCTAssertEqual failed: ("5") is not equal to ("10")
```

### Parallel Execution

Tests are always run with `--parallel` for faster execution. The number of parallel workers is automatically optimized based on your system's core count.

### Configuration

Configure via `.quality-gate.yml`:

```yaml
parallel_workers: 4    # Number of parallel test workers
test_filter: "MyTests" # Run only matching tests
```

### Test Summary

TestRunner can parse the test summary line to extract total test count and failure count:

```
Test run with 42 tests in 5 suites passed after 1.5 seconds.
```

### Test-outcome flip detection

Each run is otherwise memoryless — the gate cannot tell "this test passed last time and fails now with no source change" from "this test always fails." The flip detector closes that gap.

After the suite runs, TestRunner parses the full pass/fail roster (`parseTestRoster(_:)`), fingerprints the package's `Sources`/`Tests` + `Package.swift`, and persists a ``TestRunRecord`` per package under `.build/quality-gate-cache/test-outcomes/`. On the next run it compares against the stored record and flags any test whose outcome **flipped while the package fingerprint is unchanged** (see ``FlipDetector``) — i.e. scheduler-dependent behavior, not a code change. The diagnostic (`test.outcome-flip`) names both commits so the regression window is bounded.

An empty roster (e.g. a build failure meant no tests ran) never overwrites the stored history. All state IO is best-effort — the detector never fails the gate on its own IO.

```yaml
flipDetector:
  enabled: true    # run flip detection after the suite (default)
  strict: false    # true → a flip is an error, not a warning
```

## Topics

### Essentials

- ``TestRunner/check(configuration:)``
- ``TestRunner/parseTestOutput(_:)``
- ``TestRunner/createResult(output:exitCode:duration:)``

### Configuration

- ``TestRunner/testArguments(for:)``

### Summary Parsing

- ``TestRunner/TestSummary``
- ``TestRunner/parseTestSummary(_:)``

### Flip Detection

- ``TestRunner/parseTestRoster(_:)``
- ``TestRunner/flipDetection(roster:previous:packageFingerprint:commit:loadProxy:strict:)``
- ``TestRunner/flipDiagnostics(for:strict:)``
