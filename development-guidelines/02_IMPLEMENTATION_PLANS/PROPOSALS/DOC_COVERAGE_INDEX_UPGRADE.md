# Design Proposal: DocCoverageChecker IndexStoreInfra Upgrade

**Date:** 2026-06-03
**Author:** Justin Purnell + Claude Opus 4.6
**Status:** Draft
**Parent:** [IndexStoreInfra Upgrade Map](IndexStoreInfraUpgradeMap.md) -- Tier 2

---

## 1. Problem

DocCoverageChecker's single-pass SwiftSyntax visitor (`DocCoverageVisitor`) checks whether each `public`/`open` declaration has a doc comment in its leading trivia. This produces false positives for a common and legitimate Swift pattern: protocol extension default implementations that inherit their documentation from the protocol requirement.

Consider:

```swift
/// Performs the quality check against the given configuration.
public protocol QualityChecker {
    func check(configuration: Configuration) async throws -> CheckResult
}

extension QualityChecker {
    // No doc comment here -- but it IS documented via the protocol requirement
    public func check(configuration: Configuration) async throws -> CheckResult {
        // default implementation
    }
}
```

The visitor flags the extension method as `missing-doc` because it has no doc comment in its own leading trivia. But the API *is* documented -- the protocol requirement's doc comment serves as the canonical documentation for this method, and tools like Xcode and DocC display the inherited documentation at the call site. Forcing authors to duplicate the doc comment on every default implementation creates maintenance burden and drift risk.

This is a real source of false positives. In a project with protocol-oriented design (which quality-gate-swift itself follows heavily -- `QualityChecker`, `FixableChecker`, etc.), every default implementation triggers a spurious `missing-doc` warning.

A second gap is prioritization. When a project has dozens of undocumented public APIs, the flat list of `missing-doc` warnings provides no guidance on which APIs to document first. An API called from 40 sites across the codebase matters more than an API with zero references. Without usage data, the developer must guess.

Both gaps require cross-file analysis that SwiftSyntax alone cannot provide. IndexStoreDB's symbol resolution and reference counting unlock both capabilities.

## 2. Objective

Add an optional Pass 2 to DocCoverageChecker that uses IndexStoreInfra to:

1. **Detect inherited documentation** -- Identify protocol extension default implementations whose protocol requirement has a doc comment, and reclassify them as "documented via inheritance" rather than "missing documentation."

2. **Rank undocumented APIs by usage** -- Query IndexStoreDB reference counts to sort undocumented public APIs by call-site frequency, surfacing the highest-impact documentation gaps first.

3. **Report effective coverage** -- Adjust the `doc-coverage-summary` percentage to reflect both explicit and inherited documentation, giving a more accurate picture of actual API coverage.

Pass 2 follows the established optional-pass pattern: it requires IndexStoreDB, degrades gracefully when the index is unavailable, and never changes the gate pass/fail status relative to Pass 1 alone (inherited docs can only *improve* coverage, and usage-priority is advisory).

## 3. Proposed Design

### 3.1 Dual-Pass Architecture

The upgrade follows the same pattern established by UnreachableCodeAuditor and AppIntentsAuditor:

```
Pass 1 (Syntactic)                    Pass 2 (Cross-module)
SwiftSyntax per-file visitor          IndexStoreDB symbol queries
Always runs                           Optional -- requires index store
Produces missing-doc warnings         Produces doc-inherited info + doc-usage-priority info
Computes explicit coverage %          Adjusts to effective coverage %
```

Pass 1 remains unchanged -- the existing `DocCoverageVisitor` continues to produce `missing-doc` warnings and `doc-coverage-summary` exactly as it does today. Pass 2 is additive.

### 3.2 New File: DocCoverageIndexPass.swift

A new file `Sources/DocCoverageChecker/DocCoverageIndexPass.swift` contains all Pass 2 logic. It depends on `IndexStoreInfra` and `SwiftSyntax` (for re-parsing protocol requirements to check for doc comments).

```swift
import IndexStoreInfra
import SwiftSyntax
import SwiftParser
import QualityGateCore

/// Cross-module pass for DocCoverageChecker.
///
/// Detects inherited documentation from protocol requirements and
/// ranks undocumented APIs by usage frequency.
public struct DocCoverageIndexPass: Sendable {

    /// Inputs collected from Pass 1.
    public struct Inputs: Sendable {
        /// Diagnostics from Pass 1 (missing-doc warnings).
        public let pass1Diagnostics: [Diagnostic]
        /// Total public API count from Pass 1.
        public let totalPublicAPIs: Int
        /// Documented API count from Pass 1 (explicit docs only).
        public let documentedAPIs: Int
        /// The doc-coverage threshold from configuration, if any.
        public let threshold: Int?
    }

    /// Results produced by Pass 2.
    public struct Results: Sendable {
        /// Pass 1 diagnostics, unchanged.
        public let pass1Diagnostics: [Diagnostic]
        /// New doc-inherited info diagnostics.
        public let inheritedDiagnostics: [Diagnostic]
        /// New doc-usage-priority info diagnostics.
        public let usagePriorityDiagnostics: [Diagnostic]
        /// Adjusted summary diagnostic (replaces Pass 1 summary).
        public let adjustedSummary: Diagnostic?
        /// Number of APIs documented via inheritance.
        public let inheritedDocCount: Int
    }

    /// Run Pass 2 analysis.
    ///
    /// - Parameters:
    ///   - inputs: Aggregated results from Pass 1.
    ///   - session: An open IndexStoreDB session.
    /// - Returns: Combined results with inherited doc detection and usage ranking.
    public func run(inputs: Inputs, session: IndexStoreSession) -> Results
}
```

### 3.3 Rule: `doc-inherited` (info)

For each `missing-doc` diagnostic from Pass 1, Pass 2 attempts to determine whether the declaration is a protocol extension default implementation with an inherited doc comment:

1. **Identify the symbol's USR** -- Use `ConformanceQuery.symbolsInFiles` to find the symbol at the diagnostic's file path and line number.

2. **Check for protocol requirement relationship** -- Query IndexStoreDB for the symbol's `overrideOf` relations. If the symbol overrides or implements a protocol requirement, retrieve the requirement's USR.

3. **Check the requirement for documentation** -- Locate the protocol requirement's source file via IndexStoreDB, parse it with SwiftSyntax, and check whether the requirement declaration has a doc comment in its leading trivia.

4. **Emit diagnostic** -- If the requirement is documented, emit:
   ```
   [info] doc-inherited: 'check(configuration:)' inherits documentation from
          protocol requirement 'QualityChecker.check(configuration:)'
          at Sources/QualityGateCore/QualityChecker.swift:15
   ```

The `doc-inherited` diagnostic is severity `.info` -- it never affects the gate status. Its purpose is to explain *why* a seemingly undocumented API is actually covered, and to suppress the false positive from the effective coverage calculation.

### 3.4 Rule: `doc-usage-priority` (info)

For each `missing-doc` diagnostic from Pass 1 that was *not* resolved by `doc-inherited`, Pass 2 queries IndexStoreDB for the number of references to that symbol:

1. **Count references** -- Use `ConformanceQuery.findReferences(toUSR:in:roles:)` with roles `[.reference, .call]` to count how many sites in the project reference the undocumented API.

2. **Rank and emit** -- Sort undocumented APIs by reference count (descending) and emit up to 10 `doc-usage-priority` diagnostics:
   ```
   [info] doc-usage-priority: 'Diagnostic.init(severity:message:filePath:)' has 47
          references -- consider documenting this API first for maximum impact
   ```

This rule is purely advisory. It does not change any `missing-doc` warning severity and does not affect the coverage percentage. It guides the developer toward the highest-impact documentation work.

### 3.5 Enhancement: Adjusted Coverage Summary

When Pass 2 detects inherited documentation, the `doc-coverage-summary` diagnostic is updated to report both metrics:

```
[note] doc-coverage-summary: Documentation coverage: 78% explicit, 85% effective
       (62/80 explicitly documented, 6 inherited from protocol requirements)
```

- **Explicit coverage** = `documentedAPIs / totalPublicAPIs` (unchanged from Pass 1)
- **Effective coverage** = `(documentedAPIs + inheritedDocCount) / totalPublicAPIs`

When evaluating against the configured threshold, effective coverage is used. This means a project at 78% explicit coverage but 85% effective coverage passes an 80% threshold -- the inherited docs legitimately cover those APIs.

### 3.6 Orchestration in DocCoverageChecker.swift

The existing `check(configuration:)` method gains Pass 2 orchestration after the existing Pass 1 logic:

```swift
// After Pass 1 completes...

if configuration.docCoverage.useIndexStore {
    do {
        let project = ProjectKind.detect(at: URL(fileURLWithPath: currentDir))
        if let storePath = try StoreLocator.locate(for: project),
           let libPath = IndexStoreSession.findLibIndexStore() {
            let session = try IndexStoreSession(storePath: storePath, libPath: libPath)
            let pass2 = DocCoverageIndexPass()
            let inputs = DocCoverageIndexPass.Inputs(
                pass1Diagnostics: allDiagnostics,
                totalPublicAPIs: totalPublicAPIs,
                documentedAPIs: documentedAPIs,
                threshold: configuration.docCoverageThreshold
            )
            let results = pass2.run(inputs: inputs, session: session)
            // Merge Pass 2 diagnostics...
        }
    } catch {
        // Graceful degradation -- emit note and continue with Pass 1 results
        finalDiagnostics.append(Diagnostic(
            severity: .note,
            message: "IndexStoreDB unavailable; skipping inherited-doc detection and usage ranking",
            ruleId: "doc-coverage-index-unavailable"
        ))
    }
}
```

### 3.7 Configuration Extension

Add a `DocCoverageConfig` struct to `Configuration.swift`:

```swift
public struct DocCoverageConfig: Sendable, Codable, Equatable {
    /// Whether to use IndexStoreDB for inherited doc detection and usage ranking.
    public let useIndexStore: Bool

    /// Whether to include references from test targets when computing
    /// `doc-usage-priority` rankings. When `false` (default), only production
    /// code references are counted, so the ranking reflects API surface
    /// importance rather than test coverage. Set to `true` to include
    /// references under `Tests/` directories.
    public let includeTestReferences: Bool

    public init(useIndexStore: Bool = true, includeTestReferences: Bool = false) {
        self.useIndexStore = useIndexStore
        self.includeTestReferences = includeTestReferences
    }
}
```

Add `docCoverage: DocCoverageConfig` to `Configuration`, following the existing pattern used by `appIntentsReadiness: AppIntentsReadinessConfig` and `concurrency: ConcurrencyAuditorConfig`.

YAML configuration:

```yaml
doc-coverage:
  useIndexStore: true           # default: true
  includeTestReferences: false  # default: false -- set true to count test-file references
  threshold: 80                 # existing field, moves under doc-coverage section
```

## 4. API Surface

Internal checker; no MCP schema required.

All new types (`DocCoverageIndexPass`, `DocCoverageIndexPass.Inputs`, `DocCoverageIndexPass.Results`) are `public` for testability but are internal to the `DocCoverageChecker` module. They are not part of any external-facing API contract. No CLI flags are added -- the feature is controlled entirely through `.quality-gate.yml` configuration.

## 5. Constraints & Compliance

### Graceful Degradation

Pass 2 **never fails the gate** when the index store is unavailable. The degradation path is:

| Condition | Behavior |
|-----------|----------|
| `useIndexStore: false` | Pass 2 skipped entirely; Pass 1 results unchanged |
| `useIndexStore: true`, no index store found | Emit `.note` diagnostic; continue with Pass 1 results |
| `useIndexStore: true`, index store stale | Emit `.note` diagnostic; continue with Pass 1 results |
| `useIndexStore: true`, IndexStoreDB throws | Catch error, emit `.note`; continue with Pass 1 results |
| `useIndexStore: true`, index available | Run Pass 2; merge results |

This matches the graceful-degradation contract established by UnreachableCodeAuditor and documented in the IndexStoreInfra Upgrade Map.

### Concurrency

- `DocCoverageIndexPass` is a `Sendable` struct with no mutable state.
- `IndexStoreSession` is `@unchecked Sendable` with existing justification (created once, queried read-only from a single task).
- No new concurrency concerns are introduced.

### Swift 6 Compliance

- No `@unchecked Sendable` additions required.
- No `nonisolated(unsafe)` usage.
- All new types are value types or use existing `IndexStoreSession` patterns.

### Backward Compatibility

- Pass 1 behavior is identical to today when `useIndexStore: false` or when the index is unavailable.
- The `doc-coverage-summary` message format changes when Pass 2 runs (adds "explicit" and "effective" labels). Consumers parsing the summary text should use `ruleId` matching, not string matching.
- Threshold evaluation uses effective coverage when Pass 2 runs. This can only *improve* coverage (inherited docs count toward the threshold), so no project that currently passes will start failing.

## 6. Compute Requirements

Not compute-intensive; no backend abstraction required.

Pass 2 performs a bounded number of IndexStoreDB queries:

- One `symbolsInFiles` call per file containing a `missing-doc` diagnostic (typically < 50 files).
- One `findReferences` call per undocumented symbol to check for protocol requirement relationships (bounded by the number of `missing-doc` diagnostics, typically < 200).
- One `findReferences` call per still-undocumented symbol for usage counting.
- A small number of file reads and SwiftSyntax parses to verify protocol requirement documentation (only for symbols identified as default implementations).

Total expected latency: < 2 seconds for a project with 100 undocumented APIs. This is negligible compared to the index store open/poll time already incurred by other Pass 2 checkers sharing the same `IndexStoreSession`.

## 7. Dependencies

### Internal

| Dependency | Usage |
|------------|-------|
| `IndexStoreInfra` | `IndexStoreSession`, `ConformanceQuery`, `StoreLocator`, `ProjectKind` |
| `QualityGateCore` | `Diagnostic`, `Configuration`, `CheckResult` |
| `SwiftSyntax` / `SwiftParser` | Re-parsing protocol requirement files to check for doc comments |

All dependencies are already part of the quality-gate-swift package. No new external dependencies are introduced.

### Package.swift Change

Add `IndexStoreInfra` to the `DocCoverageChecker` target's dependency list:

```swift
.target(
    name: "DocCoverageChecker",
    dependencies: [
        "QualityGateCore",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        "IndexStoreInfra",  // NEW
    ]
),
```

## 8. Test Strategy

### New Test File

`Tests/DocCoverageCheckerTests/DocCoverageIndexPassTests.swift`

### Test Cases

| Test | What It Verifies | Key Assertion |
|------|-----------------|---------------|
| `testInheritedDocFromProtocolRequirement` | Default implementation with documented protocol requirement emits `doc-inherited` info diagnostic | Diagnostic severity is `.info`, ruleId is `doc-inherited`, message references the protocol requirement |
| `testNoInheritedDocWhenRequirementUndocumented` | Default implementation where the protocol requirement also lacks documentation does NOT emit `doc-inherited` | No `doc-inherited` diagnostic; `missing-doc` warning persists |
| `testNoInheritedDocForNonProtocolMethod` | Regular public method (not a default implementation) is unaffected | No `doc-inherited` diagnostic |
| `testUsagePriorityRanking` | Undocumented APIs are ranked by reference count, top 10 emitted | `doc-usage-priority` diagnostics are ordered by descending reference count |
| `testUsagePriorityExcludesInherited` | APIs resolved by `doc-inherited` are excluded from usage ranking | No `doc-usage-priority` for an inherited-doc symbol |
| `testAdjustedCoverageSummary` | Summary reports both explicit and effective percentages | Summary message contains "explicit" and "effective" with correct math |
| `testEffectiveCoverageUsedForThreshold` | A project below the threshold on explicit coverage but above it on effective coverage passes | `CheckResult.status` is `.passed` |
| `testGracefulDegradationMissingIndex` | When IndexStoreSession cannot be created, Pass 1 results are returned with a `.note` | No crash; `.note` diagnostic with `ruleId: "doc-coverage-index-unavailable"` |
| `testGracefulDegradationConfigDisabled` | When `useIndexStore: false`, Pass 2 is skipped entirely | No `doc-inherited` or `doc-usage-priority` diagnostics; results identical to Pass 1 |
| `testZeroUndocumentedAPIs` | When Pass 1 finds no `missing-doc` warnings, Pass 2 is a no-op | No Pass 2 diagnostics emitted |

### Testing Approach

Pass 2 tests will use the existing project's own index store (built as a prerequisite of `swift test`) rather than mocking IndexStoreDB. This follows the pattern established by `UnreachableCodeAuditorTests` -- the test target includes fixture source files with known protocol/extension patterns, and the tests verify that Pass 2 produces the expected diagnostics against those fixtures.

For graceful degradation tests, pass an invalid store path to trigger the error handling path without needing a mock.

## 9. Open Questions

1. **Should inherited docs count toward the configured threshold?**

   Proposed answer: **Yes.** Inherited documentation is real documentation -- DocC, Xcode Quick Help, and symbol graphs all surface inherited doc comments at the call site. A protocol requirement documented once effectively documents every default implementation. Counting inherited docs toward the threshold reflects the actual developer experience. If a team disagrees, they can set `useIndexStore: false` to revert to explicit-only counting.

   **Resolved: Yes.** Inherited docs count toward the threshold. This aligns with how DocC, Xcode Quick Help, and symbol graphs present documentation to developers. Teams that prefer explicit-only counting can set `useIndexStore: false`.

2. **Should `doc-usage-priority` consider test references or only production code?**

   Proposed answer: **Production code only.** Test references indicate test coverage, not API surface importance. An API called from 50 tests but zero production sites is well-tested but not necessarily high-priority for documentation. Filter `findReferences` results to exclude paths under `Tests/` directories. This can be reconsidered if users report that test-file references provide useful signal.

   **Resolved: Add an `includeTestReferences: Bool` flag (default `false`) to `DocCoverageConfig`.** Rather than hardcoding the behavior, this is now configurable. The default filters out test references (production-only ranking), but users can opt in to include test references by setting `includeTestReferences: true`. See updated `DocCoverageConfig` in Section 3.7.

3. **Should `doc-inherited` suppress the `missing-doc` warning or just add an info diagnostic alongside it?**

   Proposed answer: **Add alongside, do not suppress.** The `missing-doc` warning from Pass 1 remains in the diagnostic list so that consumers who do not use Pass 2 (or who parse diagnostics without understanding `doc-inherited`) see the same warnings they always have. The `doc-inherited` info diagnostic explains *why* the coverage is acceptable. The effective coverage percentage in the summary is where the adjustment is visible. This preserves backward compatibility for diagnostic consumers.

   **Resolved: Coexist.** `doc-inherited` info diagnostics are emitted alongside the existing `missing-doc` warnings, not as replacements. This preserves backward compatibility for consumers that parse Pass 1 diagnostics without Pass 2 awareness. The effective coverage adjustment is reflected in the summary diagnostic.

## 10. Documentation Strategy

API docs only -- this is a straightforward extension of an existing internal checker.

**Complexity Threshold Check:**
- Does it combine 3+ APIs? No -- it adds one new type with one `run` method.
- Does explanation require 50+ lines? No.
- Does it need theory/background context? No.

**Updates required:**
- Add doc comments to all public members of `DocCoverageIndexPass` (struct, nested types, `run` method).
- Update the module-level DocC comment in `DocCoverageChecker.swift` to mention Pass 2 capabilities (inherited doc detection, usage-weighted ranking).
- No tutorial, article, or narrative documentation needed.

---

## Modified Files

| File | Change |
|------|--------|
| `Sources/DocCoverageChecker/DocCoverageChecker.swift` | Add Pass 2 orchestration after existing Pass 1 logic |
| `Sources/QualityGateCore/Configuration.swift` | Add `DocCoverageConfig` struct with `useIndexStore: Bool`; add `docCoverage` property to `Configuration` |
| `Package.swift` | Add `IndexStoreInfra` dependency to `DocCoverageChecker` target |

## New Files

| File | Purpose |
|------|---------|
| `Sources/DocCoverageChecker/DocCoverageIndexPass.swift` | All Pass 2 logic: inherited doc detection, usage ranking, adjusted summary |
| `Tests/DocCoverageCheckerTests/DocCoverageIndexPassTests.swift` | Tests for Pass 2 behavior |

## Implementation Sequence

Following TDD workflow:

1. **RED:** Write `DocCoverageIndexPassTests.swift` with all test cases listed in Section 8. Tests fail because `DocCoverageIndexPass` does not exist.
2. **GREEN:**
   a. Add `DocCoverageConfig` to `Configuration.swift` with `useIndexStore: Bool`.
   b. Add `IndexStoreInfra` dependency to `DocCoverageChecker` in `Package.swift`.
   c. Implement `DocCoverageIndexPass.swift` with inherited doc detection and usage ranking.
   d. Wire Pass 2 orchestration into `DocCoverageChecker.check(configuration:)`.
3. **REFACTOR:** Extract shared protocol-requirement resolution logic if patterns emerge; ensure all types are `Sendable`.
4. **VERIFY:** Run `quality-gate --check doc-coverage` against quality-gate-swift itself and confirm inherited docs are detected for protocol extension defaults.
