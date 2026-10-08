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

/// Stands in for whatever analysis your checker actually performs.
func someConditionFailed(in configuration: Configuration) async throws -> Bool {
    false
}

public struct MyChecker: QualityChecker, Sendable {
    public let id = "my-checker"
    public let name = "My Custom Checker"
    public let summary = "The findings this checker reports, in one noun phrase"
    public let category = CheckerCategory.codeHygiene
    public let kind = CheckerKind.code
    public let effect = CheckerEffect.readOnly
    public let executesProjectCode = false

    public init() {}

    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Perform your checks...
        var diagnostics: [Diagnostic] = []

        // Add any issues found
        if try await someConditionFailed(in: configuration) {
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
/// One file the checker will scan. A real checker reads these from disk.
struct SourceFile {
    let path: String
    let lines: [String]

    func matches(glob pattern: String) -> Bool {
        fnmatch(pattern, path, 0) == 0
    }
}

public struct ConfigurationRespectingChecker: QualityChecker, Sendable {
    public let id = "configuration-respecting"
    public let name = "Configuration-Respecting Checker"
    public let summary = "Findings this checker reports, honouring the configured exclusions"
    public let category = CheckerCategory.codeHygiene
    public let kind = CheckerKind.code
    public let effect = CheckerEffect.readOnly
    public let executesProjectCode = false

    let allFiles: [SourceFile]

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

        return CheckResult(
            checkerId: id,
            status: .passed,
            diagnostics: [],
            duration: .zero
        )
    }
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

### Status Follows Severity

The severity you give a diagnostic is what the user sees and what the gate acts on. The
runner reconciles every result's status with its diagnostics, and it only ever raises: a
result returned as `.passed` that carries a `.warning` diagnostic becomes `.warning`, and
the run fails under `--strict`. One that carries an `.error` diagnostic becomes `.failed`,
and the run fails with or without `--strict`. The summary's `N warning(s)` and the `--strict` exit code
are read from one tally, so a warning cannot be printed and not gated.

So a finding you do not want to gate on is a `.note`, not a `.warning` with a `.passed`
status. And a result returned as `.warning` needs a warning-severity diagnostic to back it;
without one the gate adds a `gate.status-without-finding` warning that names your checker.

### A Dependency's Warnings Are Not the Package's

A checker that parses a build's output will see diagnostics from the package's dependencies.
Warnings and notes among them do not count against the package; errors do. Ask
``DependencyOrigin`` rather than matching paths yourself, so every checker agrees on whose a
warning is:

```swift
import QualityGateCore

func buildResult(parsed: [Diagnostic], projectRoot: String, duration: Duration) -> CheckResult {
    let scope = parsed.firstPartyScope(projectRoot: projectRoot)
    let warned = scope.counted.contains { $0.severity == .warning }
    return CheckResult(
        checkerId: "my-build",
        status: warned ? .warning : .passed,
        diagnostics: scope.reported,
        duration: duration
    )
}
```

Two things in that order matter. The status is computed from ``FirstPartyScope/counted``, after
scoping — computed before, it says `.warning` over a result with no warning left in it. And the
result carries ``FirstPartyScope/reported``, which ends with a note counting what was scoped out
and naming the packages it came from: a diagnostic dropped where nobody can see it is the
pattern this gate exists to prevent.

## Thread Safety

All checkers must be `Sendable` because they may run concurrently:

```swift
// ✅ Good: Immutable struct with Sendable properties
public struct ThreadSafeAuditor: QualityChecker, Sendable {
    public let id = "safety"
    public let name = "Safety Auditor"
    public let summary = "Force unwraps and force casts, found by parsing each file independently"
    public let category = CheckerCategory.safetySecurity
    public let kind = CheckerKind.code
    public let effect = CheckerEffect.readOnly
    public let executesProjectCode = false

    public func check(configuration: Configuration) async throws -> CheckResult {
        CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
    }
}

// ❌ Bad: Mutable state without synchronization. The compiler rejects this outright
// unless you silence it with `@unchecked Sendable` — which is how it reaches production.
public final class UnsafeChecker: QualityChecker, @unchecked Sendable {
    public let id = "unsafe"
    public let name = "Unsafe Checker"
    public let summary = "Findings from a checker that mutates shared state, which is why it is not parallel-safe"
    public let category = CheckerCategory.safetySecurity
    public let kind = CheckerKind.code
    public let effect = CheckerEffect.readOnly
    public let executesProjectCode = false

    var results: [String] = [] // Not thread-safe!

    public func check(configuration: Configuration) async throws -> CheckResult {
        results.append("started") // Data race if two checkers run concurrently
        return CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
    }
}
```

## Launching a Build Tool

A checker that starts `swift`, `xcodebuild` or anything else that may run git or a package
manager on its own account passes `environment: ChildProcessEnvironment.forBuildTool` to
`ProcessRunner.run`. Leaving `environment` out inherits the gate's, and the gate is very
often running inside a git hook.

git runs a hook with the repository it is operating on written into the environment. In a
linked worktree that includes `GIT_DIR`, for every hook; in a `pre-commit` hook it includes
`GIT_INDEX_FILE`. A build tool resolving package dependencies runs git once per dependency,
and that git obeys those variables — so it checks the dependency out of *your* repository,
which does not contain it:

    xcodebuild: error: Could not resolve package dependencies:
      Couldn’t check out revision ‘1abee2759f7663b8fcd4d71bb0bcd1ebe6c1677f’:

It only happens while the packages are unresolved, so it shows in a fresh worktree, fails
the hook, and passes when the same command is run by hand — which has no `GIT_DIR`. With an
absolute `GIT_INDEX_FILE` and no `GIT_DIR` the tool exits 0 instead, having written the
dependency's file list into the hooked repository's index.

``ChildProcessEnvironment/withoutGitRepositoryScope(_:)`` removes the variables that name a
repository, its work tree, its index or its object store
(``ChildProcessEnvironment/repositoryScopedGitVariables``) and keeps everything else —
including `GIT_SSH_COMMAND`, `GIT_ASKPASS` and the `GIT_CONFIG_*` family, which is how a
private dependency gets fetched. Do not strip `GIT_*` wholesale for a build tool.

A checker that runs git *to read the audited repository* gives git that repository's
directory as its working directory. git then finds the repository from where it is run,
with or without the scrub.

When the tool fails before it has built anything, report what was run, where, and how it
exited as a diagnostic of your own. A thrown error reaches the reader as `Checker failed:`
beside a duration of `0ms`, which says the gate broke and nothing ran.

## Testing Your Checker

Write tests using the Swift Testing framework:

```swift
import Testing
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
