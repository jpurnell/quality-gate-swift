# Implementing Custom Checkers

Create your own quality checkers by implementing the QualityChecker protocol.

## Overview

The `QualityChecker` protocol defines the contract for all quality checking modules. Each checker is responsible for a specific category of checks (building, testing, safety auditing, etc.) and returns structured results.

## Creating a Checker

To create a custom checker:

1. Create a struct that conforms to `QualityChecker`
2. Implement the `id`, `name`, and `check(configuration:)` requirements
3. Return a `CheckResult` with appropriate status and diagnostics

### Basic Implementation

```swift
import QualityGateCore

public struct MyChecker: QualityChecker, Sendable {
    public let id = "my-checker"
    public let name = "My Custom Checker"

    public init() {}

    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Perform your checks...
        var diagnostics: [Diagnostic] = []

        // Add any issues found
        if someConditionFailed {
            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Something went wrong",
                file: "/path/to/file.swift",
                line: 42,
                ruleId: "my-rule"
            ))
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = diagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }
}
```

## Respecting Configuration

Checkers should respect the project configuration:

```swift
public func check(configuration: Configuration) async throws -> CheckResult {
    // Check if this checker is enabled
    guard configuration.isCheckerEnabled(id) else {
        return CheckResult(
            checkerId: id,
            status: .skipped,
            diagnostics: [],
            duration: .zero
        )
    }

    // Use exclude patterns
    let filesToCheck = allFiles.filter { file in
        !configuration.excludePatterns.contains { pattern in
            file.matches(glob: pattern)
        }
    }

    // Respect safety exemptions
    for file in filesToCheck {
        for line in file.lines {
            if configuration.safetyExemptions.contains(where: { line.contains($0) }) {
                continue // Skip exempted lines
            }
            // Check for issues...
        }
    }

    // ...
}
```

## Using Diagnostics Effectively

Create informative diagnostics that help users fix issues:

```swift
Diagnostic(
    severity: .error,
    message: "Force unwrap detected: optional value may be nil",
    file: "/Sources/MyApp/User.swift",
    line: 42,
    column: 15,
    ruleId: "force-unwrap",
    suggestedFix: "Use optional binding: if let value = optional { ... }"
)
```

### Severity Levels

| Severity | Use When |
|----------|----------|
| `.error` | Issue must be fixed before proceeding |
| `.warning` | Issue should be addressed but isn't blocking |
| `.note` | Informational message or suggestion |

## Thread Safety

All checkers must be `Sendable` because they may run concurrently:

```swift
// ✅ Good: Immutable struct with Sendable properties
public struct SafetyAuditor: QualityChecker, Sendable {
    public let id = "safety"
    // ...
}

// ❌ Bad: Mutable state without synchronization
public class UnsafeChecker: QualityChecker {
    var results: [String] = [] // Not thread-safe!
}
```

## Testing Your Checker

Write tests using the Swift Testing framework:

```swift
import Testing
@testable import MyChecker
@testable import QualityGateCore

@Suite("MyChecker Tests")
struct MyCheckerTests {
    @Test("Detects issues in problematic code")
    func detectsIssues() async throws {
        let checker = MyChecker()
        let config = Configuration()

        let result = try await checker.check(configuration: config)

        #expect(result.status == .failed)
        #expect(result.diagnostics.count > 0)
    }

    @Test("Passes for clean code")
    func passesForCleanCode() async throws {
        let checker = MyChecker()
        let config = Configuration()

        let result = try await checker.check(configuration: config)

        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
    }
}
```
