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

After the suite runs, TestRunner parses the full pass/fail roster (`parseTestRoster(_:)`), fingerprints the package's `Sources`/`Tests` + `Package.swift`, and persists a `TestRunRecord` per package under `.build/quality-gate-cache/test-outcomes/`. On the next run it compares against the stored record and flags any test whose outcome **flipped while the package fingerprint is unchanged** (see `FlipDetector` in VigilKit) — i.e. scheduler-dependent behavior, not a code change. The diagnostic (`test.outcome-flip`) names both commits so the regression window is bounded.

An empty roster (e.g. a build failure meant no tests ran) never overwrites the stored history. All state IO is best-effort — the detector never fails the gate on its own IO.

```yaml
flipDetector:
  enabled: true    # run flip detection after the suite (default)
  strict: false    # true → a flip is an error, not a warning
```

### Deliberate stress runs (timing-tagged tests)

Flip detection is *passive* — it waits for a race to surface. Stress mode *provokes* one. Tests carrying a `// TIMING:` comment are self-identifying stress candidates (teardown-liveness bounds, reconnect budgets, phase-sync):

```swift
import Testing

// TIMING: teardown must release the port within the liveness bound
@Test func teardownIsPrompt() {
    let bound = Duration.milliseconds(50)
    let elapsed = ContinuousClock().measure { /* tear the fixture down here */ }
    #expect(elapsed < bound)
}
```

When `stress.runs > 1`, TestRunner scans `Tests/` for those markers (via `TimingTestScanner`, AST-based so a `// TIMING:` inside a string or a trailing body comment does **not** tag anything), re-runs *only* the tagged tests that many times — optionally under a background CPU-contention harness sized to `cores − 1` — and reports any test that was **not unanimous across the identical runs** (`stressFlips(rosters:)`). Because every run shares the same commit and source, a non-unanimous outcome is a *definitive* race, a stronger signal than a cross-commit flip. The `test.stress-flip` diagnostic names the pass/fail tally.

This is meant for **per-release / nightly** cadence, not per-commit — `runs: 1` (the default) is a no-op with zero overhead. No tagged tests are found → a single `.note`, no extra runs.

```yaml
stress:
  runs: 1          # >1 enables stress mode; re-run each tagged test this many times
  contention: false # background CPU load during the runs (best-effort)
  strict: false     # true → an intra-batch flip is an error, not a warning
  marker: "// TIMING:"
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

- ``TestRunner/flipDetection(roster:previous:packageFingerprint:commit:loadProxy:strict:)``
- ``TestRunner/flipDiagnostics(for:strict:)``

### Stress Runs

Roster parsing, flip detection and stress analysis themselves live in VigilKit
(`TestRosterParser`, `FlipDetector`, `StressAnalysis`, `TimingTestScanner`),
extracted so the same rules run standalone from the `vigil` command. They cannot
be curated here: DocC resolves symbol links within a module, and a link that
points outside one silently documents nothing.
