# Design Proposal: QualityGateTestKit

## 1. Problem

Three of 22 auditors have dedicated `TestHelpers.swift` files (LoggingAuditor, ConcurrencyAuditor, PointerEscapeAuditor). All three follow an identical pattern: an `enum TestHelpers` with a static `audit(_ code: String, ...params) async throws -> CheckResult` method. The remaining auditors either inline ad-hoc helpers in each test file or instantiate auditors directly with boilerplate setup.

This creates three problems:

| Problem | Impact |
|---|---|
| **Duplicated boilerplate** | Each auditor test target reinvents the "audit this source string" pattern with slightly different signatures |
| **No assertion helpers** | Tests repeat `#expect(result.diagnostics.contains { $0.ruleId == ... })` and `#expect(result.status == .failed)` patterns manually, with inconsistent assertion messages |
| **No path for plugin authors** | The Community Plugin Ecosystem proposal requires external developers to test their checkers; without a published test harness they must reverse-engineer internal patterns from auditor source |

## 2. Objective

Provide a single `QualityGateTestKit` Swift package that standardizes checker testing for both built-in auditors and community plugins. The package provides source-string auditing, diagnostic assertions, configuration builders, and source fixtures — replacing the three ad-hoc `TestHelpers.swift` files and giving plugin authors a documented testing API from day one.

## 3. Proposed API

### 3.1 Source Auditing

The primary entry point runs a checker against an inline Swift source string:

```swift
/// Run a checker against inline Swift source and return the check result.
public func auditSource(
    _ source: String,
    fileName: String = "Test.swift",
    with checker: some QualityChecker,
    configuration: Configuration = .default
) async throws -> CheckResult
```

This replaces the three existing `TestHelpers.audit()` methods. The `fileName` parameter allows tests to verify file-path-sensitive behavior (e.g., checkers that skip `Tests/` directories).

For auditors that need multi-file context:

```swift
/// Run a checker against multiple source files.
public func auditSources(
    _ sources: [String: String],   // fileName → source code
    with checker: some QualityChecker,
    configuration: Configuration = .default
) async throws -> CheckResult
```

### 3.2 Diagnostic Assertions

Replace manual `#expect(result.diagnostics.contains { ... })` patterns with purpose-built assertions:

```swift
/// Assert a specific rule was triggered at a specific line.
public func expectDiagnostic(
    in result: CheckResult,
    ruleId: String,
    severity: Diagnostic.Severity? = nil,
    atLine line: Int? = nil,
    messageContaining substring: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
)

/// Assert a specific rule was NOT triggered.
public func expectNoDiagnostic(
    in result: CheckResult,
    ruleId: String,
    sourceLocation: SourceLocation = #_sourceLocation
)

/// Assert no diagnostics were emitted (clean pass).
public func expectClean(
    _ result: CheckResult,
    sourceLocation: SourceLocation = #_sourceLocation
)

/// Assert the result has a specific status.
public func expectStatus(
    _ result: CheckResult,
    _ status: CheckResult.Status,
    sourceLocation: SourceLocation = #_sourceLocation
)

/// Assert the result contains exactly N diagnostics with the given rule ID.
public func expectDiagnosticCount(
    in result: CheckResult,
    ruleId: String,
    count: Int,
    sourceLocation: SourceLocation = #_sourceLocation
)
```

All assertion functions use `#_sourceLocation` to report failures at the test call site, not inside the helper.

### 3.3 Configuration Builders

A builder API for constructing test configurations without touching YAML:

```swift
public struct TestConfiguration {
    public static var `default`: Configuration { get }

    public static func with(
        enabledCheckers: [String]? = nil,
        excludePatterns: [String]? = nil,
        overrides: [String: String]? = nil
    ) -> Configuration

    /// Merge auditor-specific config into a base configuration.
    public static func with(
        base: Configuration = .default,
        concurrency: Configuration.ConcurrencyAuditorConfig? = nil,
        logging: Configuration.LoggingAuditorConfig? = nil,
        pointerEscape: Configuration.PointerEscapeAuditorConfig? = nil,
        security: Configuration.SecurityAuditorConfig? = nil
        // ... one parameter per auditor config
    ) -> Configuration
}
```

This replaces the pattern where each `TestHelpers.audit()` accepts raw auditor init parameters (e.g., `firstPartyModules: Set<String>`, `allowedEscapeFunctions: Set<String>`) and manually threads them through.

### 3.4 Source Fixtures

Common Swift source patterns used across multiple auditor tests:

```swift
public enum SourceFixtures {
    /// Minimal valid Swift file (single struct, one public method, documented).
    public static let minimalValid: String

    /// Class with stored properties and deinit.
    public static let classWithDeinit: String

    /// SwiftUI View with accessibility modifiers.
    public static let accessibleView: String

    /// Actor with isolated state.
    public static let basicActor: String

    /// File with common force-unwrap patterns.
    public static let forceUnwrapPatterns: String

    /// Empty file (edge case).
    public static let empty: String
}
```

Fixtures are intentionally minimal. They exist to test edge cases (empty files, minimal valid files) and to provide starting points that plugin authors can extend — not to be exhaustive test data.

## 4. Package Structure

```
QualityGateTestKit/
├── Sources/
│   └── QualityGateTestKit/
│       ├── AuditHelpers.swift          // auditSource(), auditSources()
│       ├── DiagnosticAssertions.swift   // expectDiagnostic(), expectClean(), etc.
│       ├── ConfigurationBuilders.swift  // TestConfiguration
│       └── SourceFixtures.swift         // Common source patterns
├── Tests/
│   └── QualityGateTestKitTests/
│       ├── AuditHelpersTests.swift
│       ├── DiagnosticAssertionTests.swift
│       └── ConfigurationBuilderTests.swift
└── Package.swift
```

**Dependencies:**
- `QualityGatePluginSDK` (or `QualityGateCore` if shipping before the SDK extraction)
- Swift Testing framework (for `#_sourceLocation` support)
- No dependency on SwiftSyntax, Yams, or ArgumentParser

**Swift version:** Matches the SDK target. If the SDK ships at Swift 5.9, TestKit ships at 5.9.

## 5. Migration Plan for Built-in Auditors

After `QualityGateTestKit` ships, the three existing `TestHelpers.swift` files are replaced:

| Auditor | Current Pattern | Migration |
|---|---|---|
| ConcurrencyAuditor | `TestHelpers.audit(code, firstPartyModules:, ...)` | `auditSource(code, with: ConcurrencyAuditor(...), configuration: TestConfiguration.with(concurrency: ...))` |
| LoggingAuditor | `TestHelpers.audit(code, projectType:, ...)` | `auditSource(code, with: LoggingAuditor(config: ...), configuration: TestConfiguration.with(logging: ...))` |
| PointerEscapeAuditor | `TestHelpers.audit(code, allowedEscapeFunctions:)` | `auditSource(code, with: PointerEscapeAuditor(allowedEscapeFunctions: ...), configuration: .default)` |

The three `TestHelpers.swift` files are deleted after migration. Auditors without existing helpers simply adopt `auditSource()` directly.

## 6. Implementation Plan

| # | Step | Effort | Dependencies |
|---|---|---|---|
| 1 | Create `QualityGateTestKit` package with `auditSource()` and `auditSources()` | Small | QualityGateCore |
| 2 | Implement diagnostic assertion functions with `#_sourceLocation` propagation | Small | Step 1 |
| 3 | Implement `TestConfiguration` builder with per-auditor config parameters | Small | Step 1 |
| 4 | Create `SourceFixtures` with minimal valid, empty, and common pattern fixtures | Small | — |
| 5 | Write self-tests: verify assertions pass/fail correctly, verify configuration threading | Medium | Steps 1-4 |
| 6 | Migrate ConcurrencyAuditorTests to use TestKit, delete `TestHelpers.swift` | Small | Step 5 |
| 7 | Migrate LoggingAuditorTests to use TestKit, delete `TestHelpers.swift` | Small | Step 5 |
| 8 | Migrate PointerEscapeAuditorTests to use TestKit, delete `TestHelpers.swift` | Small | Step 5 |
| 9 | Achieve 100% public API doc coverage on QualityGateTestKit | Small | Steps 1-4 |

## 7. Success Criteria

- `auditSource("let x: Int! = nil", with: SafetyAuditor())` returns a `CheckResult` with diagnostics for the implicitly unwrapped optional
- `expectDiagnostic(in: result, ruleId: "safety.implicitly-unwrapped-optional", atLine: 1)` passes
- `expectClean(result)` fails with a message identifying the unexpected diagnostics
- `expectNoDiagnostic(in: result, ruleId: "safety.force-cast")` passes when no force cast exists
- `TestConfiguration.with(logging: .init(projectType: "library"))` produces a valid `Configuration` with the logging section populated
- All three existing `TestHelpers.swift` files are deleted with no test regressions
- A plugin author can write a complete test suite for a custom checker using only `QualityGateTestKit` — no imports from `QualityGateCore` internals needed
- `QualityGateTestKit` has zero dependency on SwiftSyntax

## 8. Open Questions

1. **Should TestKit include a `FixResult` assertion helper?** The `FixableChecker` protocol produces `FixResult` with `FileModification` entries. Testing fixes requires asserting on file modifications, not just diagnostics. Recommendation: include `expectFix(in:filePath:descriptionContaining:)` from day one. The `--fix-plugins` gate in the Community Plugin Ecosystem proposal means plugin authors need to test their fixes, and the assertion surface is small.

2. **Should `auditSource()` accept a temporary directory path for checkers that read the filesystem?** Some auditors (StatusAuditor, DependencyAuditor) read files beyond source code (e.g., `Package.swift`, `.quality-gate.yml`). Recommendation: add an optional `workingDirectory: URL?` parameter that creates a temporary directory with the provided source files. Default to in-memory-only for the common case.

---

**Date:** 2026-04-29
**Author:** Justin Purnell + Claude Opus 4.6
