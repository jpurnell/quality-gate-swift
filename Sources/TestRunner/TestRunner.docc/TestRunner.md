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
