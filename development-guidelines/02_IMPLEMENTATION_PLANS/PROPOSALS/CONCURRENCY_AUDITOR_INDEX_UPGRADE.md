# Design Proposal: ConcurrencyAuditor IndexStoreInfra-Powered Pass 2

**Date:** 2026-06-03
**Status:** Draft
**Author:** Justin Purnell + Claude Opus 4.6
**Parent:** IndexStoreInfraUpgradeMap.md (Phase 1)

---

## 1. Objective

**Problem:** The ConcurrencyAuditor analyzes each Swift source file independently via a single `ConcurrencyVisitor` (SwiftSyntax `SyntaxVisitor`). This per-file model cannot detect concurrency issues that span multiple files -- the exact category of bugs that makes Swift 6 migration painful.

Three concrete gaps:

| Gap | What Happens Today | Impact |
|-----|-------------------|--------|
| **`@unchecked Sendable` overuse** | A type is marked `@unchecked Sendable` with a valid justification. The auditor accepts it. But the type is never actually sent across isolation boundaries -- the annotation is unnecessary complexity and a future maintenance hazard. | Developers accumulate `@unchecked Sendable` annotations defensively during migration, then never clean them up. The justification system catches *bad* justifications but cannot catch *unnecessary* ones. |
| **Cross-file stored properties** | Pass 1 checks stored properties of Sendable classes within the declaring file. But Swift allows adding stored properties via extensions in other files (within the same module). A Sendable class can gain a mutable `var` in `Extensions/MyClass+Storage.swift` that Pass 1 never sees. | Silent concurrency violation. The compiler catches this in strict concurrency mode, but teams using `@preconcurrency` or incremental adoption miss it entirely. |
| **Unnecessary `@preconcurrency import`** | Pass 1 flags `@preconcurrency import` of first-party modules. But for third-party modules, there is no way to know whether `@preconcurrency` is still needed without checking whether any imported symbol is used in a Sendable-requiring context. | Stale `@preconcurrency` annotations suppress compiler warnings that would otherwise guide the developer toward proper Sendable conformance. |

Cross-file Sendable validation is the single biggest gap in Swift 6 static tooling. The compiler enforces these rules at build time, but only in strict concurrency mode. Teams doing incremental adoption -- the majority -- get no cross-file feedback until they flip the switch and face hundreds of errors. This proposal fills that gap.

---

## 2. Architecture

### Dual-Pass Design

Following the established pattern from UnreachableCodeAuditor:

```
ConcurrencyAuditor.check(configuration:)
    |
    +-- Pass 1 (Syntactic)           -- always runs
    |   ConcurrencyVisitor walks     -- per-file SwiftSyntax
    |   each .swift file             -- 8 existing rules
    |   independently                -- produces [Diagnostic]
    |
    +-- Pass 2 (Cross-module)        -- optional, new
        ConcurrencyIndexPass.run()   -- uses IndexStoreDB
        queries cross-file           -- 3 new rules
        relationships                -- produces [Diagnostic]
        |
        +-- graceful degradation: if index unavailable,
            emit .note and return empty diagnostics
```

Pass 2 runs after Pass 1 completes. Results from both passes are merged into a single `CheckResult`. Pass 2 never modifies, promotes, or suppresses Pass 1 diagnostics.

### New File: `ConcurrencyIndexPass.swift`

A single new file in `Sources/ConcurrencyAuditor/` containing the cross-module analysis logic. Follows the same structural pattern as `UnreachableCodeAuditor/IndexStorePass.swift`:

- `struct ConcurrencyIndexPass` with a nested `Inputs` struct
- A static `run(inputs:)` method returning `[Diagnostic]`
- All IndexStoreDB interaction isolated to this file
- Pass 1 code (`ConcurrencyAnalyzer.swift`, `ConcurrencyAuditor.swift`) remains untouched

### Integration Point in `ConcurrencyAuditor.swift`

The `check(configuration:)` method gains a Pass 2 call after its existing `auditDirectory` loop:

```swift
// After Pass 1 completes:
if configuration.concurrency.useIndexStore {
    do {
        let indexDiagnostics = try ConcurrencyIndexPass.run(inputs: .init(
            rootURL: URL(fileURLWithPath: currentDir),
            firstPartyModules: firstPartyModules,
            justificationKeyword: justificationKeyword,
            trackIsolationDepth: configuration.concurrency.trackIsolationDepth
        ))
        allDiagnostics.append(contentsOf: indexDiagnostics)
    } catch {
        // Graceful degradation: index unavailable
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "IndexStoreDB unavailable; cross-file concurrency checks skipped (\(error.localizedDescription))",
            filePath: "",
            lineNumber: 0,
            columnNumber: 0,
            ruleId: "concurrency.index-unavailable"
        ))
    }
}
```

The `auditSource(_:fileName:configuration:)` method (single-file mode) does NOT run Pass 2 -- it remains purely syntactic.

---

## 3. API

### `ConcurrencyIndexPass`

```swift
/// Cross-file concurrency analysis backed by IndexStoreDB.
///
/// Implements three rules that require cross-file symbol resolution:
/// - `concurrency.sendable-crosses-isolation` (warning)
/// - `concurrency.sendable-non-sendable-stored-property` (warning)
/// - `concurrency.preconcurrency-import-unnecessary` (info)
struct ConcurrencyIndexPass {

    struct Inputs {
        /// Root of the project being audited.
        var rootURL: URL
        /// First-party module names (from Package.swift).
        var firstPartyModules: Set<String>
        /// Keyword identifying justification comments.
        var justificationKeyword: String
        /// When `true`, Rule 1 builds a send-graph to track isolation
        /// depth (e.g., actor A -> actor B -> actor C). Adds analysis
        /// time; disabled by default. See Q2 in Open Questions.
        var trackIsolationDepth: Bool = false
    }

    /// Runs all three cross-file concurrency rules.
    ///
    /// - Parameter inputs: Configuration and project context.
    /// - Returns: Diagnostics from cross-file analysis.
    /// - Throws: If IndexStoreDB cannot be opened (caller should
    ///   catch and emit a `.note` for graceful degradation).
    static func run(inputs: Inputs) throws -> [Diagnostic]
}
```

### New Rules

#### Rule 1: `concurrency.sendable-crosses-isolation` (warning)

**Detection logic:**

1. Use `ConformanceQuery.findConformers(ofProtocol: "Sendable")` to locate all types with explicit Sendable conformance (including `@unchecked Sendable`).
2. For each conformer, use `ConformanceQuery.findReferences(toUSR:)` to locate all usage sites.
3. For each usage site, determine the isolation context by examining the enclosing declaration's attributes (`@MainActor`, actor type, `nonisolated`).
4. If ALL usage sites share a single isolation domain (or are all `nonisolated`), the type never actually crosses an isolation boundary -- the Sendable conformance may be unnecessary.

**Emitted diagnostic:**

```
warning: concurrency.sendable-crosses-isolation
  Sources/Cache/ImageCache.swift:12:1
  '@unchecked Sendable' on 'ImageCache' may be unnecessary;
  all 7 usage sites are within MainActor isolation.
  Suggested fix: Remove @unchecked Sendable if this type
  does not need to cross isolation boundaries.
```

**Limitations:** This rule uses a conservative heuristic. It reports `warning` severity (see Q1 resolution). Be aware that false positives are possible because:
- Generic code may send the type across boundaries without an explicit reference
- The index may not capture all usage sites (e.g., in test targets not indexed)
- Dynamic dispatch through protocol existentials is invisible to the index

#### Rule 2: `concurrency.sendable-non-sendable-stored-property` (warning)

**Detection logic:**

1. From Pass 1's existing `checkSendableClassMembers`, collect all types declared as `Sendable` (plain, not `@unchecked`).
2. For each Sendable type, use `ConformanceQuery.findReferences(toUSR:roles: [.definition, .extension])` to locate all extensions of the type across the project.
3. For each extension, parse the extension body with SwiftSyntax and check for stored properties.
4. Flag any mutable stored property (`var`) or non-`@Sendable` closure property found in a cross-file extension.

**Emitted diagnostic:**

```
warning: concurrency.sendable-non-sendable-stored-property
  Sources/Extensions/NetworkClient+Properties.swift:8:5
  Sendable class 'NetworkClient' has mutable stored property
  'requestCount' added in a cross-file extension; declare it
  'let' or use @unchecked Sendable with a justification.
```

**Note:** This rule elevates to `warning` (not `info`) because a mutable stored property on a Sendable class is a concrete data race risk, not a stylistic concern. This matches the severity of the existing same-file rule `concurrency.sendable-class-mutable-state`.

#### Rule 3: `concurrency.preconcurrency-import-unnecessary` (info)

**Detection logic:**

1. From Pass 1's existing import visitor, collect all `@preconcurrency import` declarations (both first-party and third-party).
2. For each imported module, use `ConformanceQuery.symbolsInFiles` to identify which symbols from that module are used in the current file.
3. For each used symbol, check whether it appears in a Sendable-requiring context (stored property of a Sendable type, closure parameter, `@Sendable` function argument).
4. If NO symbols from the imported module appear in a Sendable-requiring context, the `@preconcurrency` annotation provides no benefit.

**Emitted diagnostic:**

```
info: concurrency.preconcurrency-import-unnecessary
  Sources/Networking/APIClient.swift:3:1
  '@preconcurrency import Alamofire' may be unnecessary;
  no symbols from 'Alamofire' are used in a Sendable-requiring
  context in this file.
  Suggested fix: Remove @preconcurrency and verify no new
  concurrency warnings appear.
```

**Note:** This is `info` because the analysis is best-effort -- indirect Sendable requirements through generic constraints may not be visible to the index.

---

## 4. MCP Schema

Internal checker; no MCP schema required.

---

## 5. Constraints

### Sendable Compliance

All new types must be `Sendable`. `ConcurrencyIndexPass` is a value type with no mutable state (static method only). `Inputs` is a struct of `Sendable` types (`URL`, `Set<String>`, `String`).

The `IndexStoreSession` from IndexStoreInfra is already `@unchecked Sendable` (with justification: read-only queries from a single task). Pass 2 creates one session, queries it synchronously, and discards it -- no concurrent access.

### Graceful Degradation

Pass 2 must never fail the quality gate when the index is unavailable. Specific scenarios:

| Scenario | Behavior |
|----------|----------|
| No IndexStoreDB available (Xcode CLT not installed) | Catch `IndexStoreLibrary` init failure, emit `.note`, return `[]` |
| Index store path not found (no prior build) | Catch `IndexStoreDB` init failure, emit `.note`, return `[]` |
| Index is stale (source changed since last build) | Proceed with best-effort analysis; stale data may cause false negatives but never false positives |
| `useIndexStore: false` in configuration | Skip Pass 2 entirely, no `.note` emitted |
| `libIndexStore.dylib` not found | `IndexStoreSession.findLibIndexStore()` returns `nil`, emit `.note`, return `[]` |

The `.note` diagnostic uses rule ID `concurrency.index-unavailable` and is informational only. It does not count as an error or warning.

### Gate Safety

Pass 2 rules at `info` severity (`preconcurrency-import-unnecessary`) never fail the gate regardless of `--strict` mode. The `sendable-crosses-isolation` and `sendable-non-sendable-stored-property` rules at `warning` severity fail the gate only in `--strict` mode, consistent with other warning-level rules. Teams that find `sendable-crosses-isolation` too noisy due to false positives can use severity overrides to demote it to `info`.

### Performance

Pass 2 adds one IndexStoreDB session open and `O(n)` queries where `n` is the number of Sendable conformances plus `@preconcurrency` imports in the project. For a typical project (10-50 Sendable types, 5-15 preconcurrency imports), this adds <500ms to the audit. The index is already in memory from the build step; opening the session is the dominant cost (~100ms).

---

## 6. Backend

Not compute-intensive; no backend abstraction required.

---

## 7. Dependencies

### Internal

| Module | Usage | Already Exists |
|--------|-------|---------------|
| `IndexStoreInfra` | `IndexStoreSession`, `ConformanceQuery`, `StoreLocator`, `ProjectKind`, `SourceWalker` | Yes |
| `QualityGateCore` | `Diagnostic`, `Configuration`, `ConcurrencyAuditorConfig` | Yes |
| `SwiftSyntax` / `SwiftParser` | Parse extension bodies for stored-property checks in Rule 2 | Yes (already a ConcurrencyAuditor dependency) |

### Transitive

| Package | Via | Version |
|---------|-----|---------|
| `IndexStoreDB` | `IndexStoreInfra` | Already pinned in Package.resolved |

### Package.swift Changes

Add `IndexStoreInfra` to the ConcurrencyAuditor target's dependency list:

```swift
.target(
    name: "ConcurrencyAuditor",
    dependencies: [
        "QualityGateCore",
        "IndexStoreInfra",  // NEW: cross-file concurrency analysis
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
    ]
),
```

No new external packages are introduced. `IndexStoreDB` is already a transitive dependency via `IndexStoreInfra`.

### ConformanceQuery Additions

Two new helpers should be added to `ConformanceQuery` in IndexStoreInfra (shared infrastructure, not ConcurrencyAuditor-specific):

1. **`findExtensions(ofUSR:in:)`** -- Returns all extension declarations for a type by USR. Needed by Rule 2 to locate cross-file extensions of Sendable types.

2. **`symbolsFromModule(_:usedInFile:in:)`** -- Returns symbols from a named module that are referenced in a specific file. Needed by Rule 3 to determine which imported symbols are actually used.

These are general-purpose queries that other checkers (MemoryLifecycleGuard, DocCoverageChecker) will also need, per the IndexStoreInfraUpgradeMap.

---

## 8. Test Strategy

### New Test File

`Tests/ConcurrencyAuditorTests/ConcurrencyIndexPassTests.swift`

### Test Categories

#### Rule 1: `sendable-crosses-isolation` Tests

| Test | Input | Expected |
|------|-------|----------|
| `testSendableUsedInSingleIsolationDomain` | `@unchecked Sendable` type used only in `@MainActor` context | `warning` diagnostic emitted |
| `testSendableUsedAcrossIsolationBoundaries` | `@unchecked Sendable` type used in both `@MainActor` and a custom actor | No diagnostic |
| `testSendableUsedInNonisolatedOnly` | `@unchecked Sendable` type used only in nonisolated code | `warning` diagnostic (never crosses a boundary) |
| `testPlainSendableNotFlagged` | Type with plain `Sendable` conformance (not `@unchecked`) used in single domain | No diagnostic (rule targets `@unchecked` only) |

#### Rule 2: `sendable-non-sendable-stored-property` Tests

| Test | Input | Expected |
|------|-------|----------|
| `testCrossFileVarOnSendableClass` | Sendable class with `var` in a different-file extension | `warning` diagnostic |
| `testCrossFileLetOnSendableClass` | Sendable class with `let` (Sendable type) in extension | No diagnostic |
| `testCrossFileNonSendableClosureOnSendableClass` | Sendable class with non-`@Sendable` closure in extension | `warning` diagnostic |
| `testSameFileExtensionNotDuplicated` | Sendable class with extension in same file | No diagnostic (already caught by Pass 1) |
| `testUncheckedSendableNotChecked` | `@unchecked Sendable` class with `var` in extension | No diagnostic (author opted out of compiler checks) |

#### Rule 3: `preconcurrency-import-unnecessary` Tests

| Test | Input | Expected |
|------|-------|----------|
| `testPreconcurrencyImportWithSendableUsage` | `@preconcurrency import Foo` where `Foo.Bar` is a stored property of a Sendable class | No diagnostic |
| `testPreconcurrencyImportWithoutSendableUsage` | `@preconcurrency import Foo` where `Foo.Bar` is only used in non-Sendable contexts | `info` diagnostic |
| `testPreconcurrencyImportNoUsage` | `@preconcurrency import Foo` where no symbols from `Foo` are used | `info` diagnostic |
| `testFirstPartyPreconcurrencyStillFlaggedByPass1` | `@preconcurrency import MyModule` (first-party) | Pass 1 `error` still emitted; Pass 2 does not duplicate |

#### Graceful Degradation Tests

| Test | Input | Expected |
|------|-------|----------|
| `testIndexUnavailableEmitsNote` | `useIndexStore: true` but no index store found | Single `.note` with rule `concurrency.index-unavailable` |
| `testIndexDisabledNoNote` | `useIndexStore: false` | No diagnostics from Pass 2, no `.note` |
| `testPass1UnaffectedWhenIndexFails` | Index unavailable, source has Pass 1 violations | Pass 1 diagnostics still emitted |

### Test Infrastructure

Tests for Rules 1-3 require IndexStoreDB to be available. Two strategies:

1. **Real index tests** (integration): Create a small multi-file Swift fixture, build it with `swift build -Xswiftc -index-store-path`, then run Pass 2 against the resulting index. These tests are guarded by `#if canImport(IndexStoreDB)` and marked with a `@Tag(.integration)` trait (Swift Testing).

2. **Mock index tests** (unit): Extract the analysis logic into pure functions that accept symbol reference lists and isolation context maps. Test these functions directly without IndexStoreDB. This covers the logic; integration tests cover the IndexStoreDB query layer.

Graceful degradation tests do not require IndexStoreDB and run as standard unit tests.

---

## 9. Open Questions

### Q1: Should `sendable-crosses-isolation` be `info` or `warning`?

**Recommendation: `info`.**

The rule uses heuristic analysis -- it cannot see all usage sites (test targets, dynamic dispatch, generic instantiation). A false positive at `warning` severity would block the gate in `--strict` mode, which contradicts the principle that Pass 2 should never *introduce* gate failures for correct code. Teams that want to enforce Sendable hygiene can use severity overrides (`overrides: { concurrency.sendable-crosses-isolation: warning }`) to promote it.

**Resolved: `warning`.** The user agreed with the recommendation's reasoning but chose `warning` severity. Teams that find false positives too noisy can use severity overrides to demote it back to `info`.

### Q2: Should we track actor isolation depth for `sendable-crosses-isolation`?

**Recommendation: Defer to v2.**

The current design checks whether a type is used in more than one isolation domain. Tracking isolation *depth* (e.g., "sent from actor A to actor B through an intermediary") would require building a send-graph, which is significantly more complex. The single-vs-multiple-domain check catches the majority case (defensive `@unchecked Sendable` during migration) without the graph complexity.

**Resolved: Include behind a flag (`trackIsolationDepth: Bool`, default `false`).** The capability is valuable but should not be enabled by default since the send-graph analysis may slow audits noticeably. Keeping it off by default also avoids noise fatigue -- users who always see depth diagnostics may learn to ignore them. Opt-in ensures the feature is used intentionally by teams that need it. The flag is added to `ConcurrencyIndexPass.Inputs` and `ConcurrencyAuditorConfig`.

### Q3: Should Rule 2 check `@unchecked Sendable` types for cross-file stored properties?

**Recommendation: No.**

If a type is `@unchecked Sendable`, the author has explicitly opted out of compiler-enforced Sendable safety (with a justification). Flagging cross-file stored properties on such types would contradict the author's stated intent. The existing `unchecked-sendable-no-justification` rule already ensures the opt-out is deliberate.

**Resolved: Agreed with recommendation.** Rule 2 will not check `@unchecked Sendable` types for cross-file stored properties. The author's explicit opt-out (with required justification) is sufficient.

### Q4: How should Pass 2 handle extensions in test targets?

**Recommendation: Exclude test targets from Rule 2 analysis.**

Test targets frequently extend production types with convenience methods and mock properties. These extensions are not shipped in the production binary and do not represent real Sendable violations. Pass 2 should filter extensions by module, excluding modules whose target type is `"test"` (using the same `targetType(forModule:)` heuristic from UnreachableCodeAuditor).

**Resolved: Agreed with recommendation.** Test targets will be excluded from Rule 2 analysis using the `targetType(forModule:)` heuristic.

---

## 10. Documentation

**Narrative article required.** This proposal combines three rules that share a common theme (cross-file Sendable safety) and requires understanding of Swift 6 concurrency concepts (isolation domains, Sendable protocol, actor boundaries, `@preconcurrency`). A reference-style DocC page listing the three rules would not provide sufficient context.

### Required Documentation Artifacts

| Artifact | Location | Content |
|----------|----------|---------|
| **DocC narrative article** | `Sources/ConcurrencyAuditor/ConcurrencyAuditor.docc/CrossFileConcurrencyAnalysis.md` | Explains the dual-pass architecture, when Pass 2 runs, what each rule detects, how to configure `useIndexStore`, examples of true positives and false positives, guidance on responding to each diagnostic |
| **Rule reference updates** | `Sources/ConcurrencyAuditor/ConcurrencyAuditor.docc/ConcurrencyAuditorGuide.md` | Add three new rule entries to the existing rule catalog with the same format as the 8 existing rules |
| **Configuration reference** | `.quality-gate.yml` inline comments | Document `useIndexStore` and `trackIsolationDepth` keys in the `concurrency:` section |

### DocC Article Outline

1. **When Single-File Analysis Falls Short** -- Concrete example of a Sendable class with a cross-file extension adding mutable state. Show that Pass 1 cannot detect this.
2. **How Pass 2 Works** -- Brief explanation of IndexStoreDB, what it queries, how it degrades gracefully.
3. **Rule: `sendable-crosses-isolation`** -- What it detects, why it is `warning`, how to respond (remove `@unchecked Sendable` or demote to `info` via severity overrides if false positives are too noisy).
4. **Rule: `sendable-non-sendable-stored-property`** -- What it detects, why it is `warning`, interaction with `@unchecked Sendable` types.
5. **Rule: `preconcurrency-import-unnecessary`** -- What it detects, relationship to the existing `preconcurrency-first-party-import` rule.
6. **Configuration** -- `useIndexStore` toggle, `trackIsolationDepth` opt-in flag, severity overrides, interaction with `--strict`.
7. **Troubleshooting** -- "I see `concurrency.index-unavailable`" flow: build the project first, verify Xcode CLT installed, check index store path.

---

## Implementation Plan

| # | Step | Effort | Dependencies | Files |
|---|------|--------|-------------|-------|
| 1 | Add `useIndexStore` and `trackIsolationDepth` (default `false`) to `ConcurrencyAuditorConfig` | Small | None | `Configuration.swift` |
| 2 | Add `findExtensions(ofUSR:in:)` and `symbolsFromModule(_:usedInFile:in:)` to `ConformanceQuery` | Medium | None | `ConformanceQuery.swift` |
| 3 | Create `ConcurrencyIndexPass.swift` with `Inputs` struct and `run(inputs:)` method; implement Rule 2 (`sendable-non-sendable-stored-property`) first -- it has the clearest detection logic | Medium | Steps 1, 2 | `ConcurrencyIndexPass.swift` |
| 4 | Write tests for Rule 2 (unit + integration) | Medium | Step 3 | `ConcurrencyIndexPassTests.swift` |
| 5 | Implement Rule 3 (`preconcurrency-import-unnecessary`) | Medium | Steps 2, 3 | `ConcurrencyIndexPass.swift` |
| 6 | Write tests for Rule 3 | Small | Step 5 | `ConcurrencyIndexPassTests.swift` |
| 7 | Implement Rule 1 (`sendable-crosses-isolation`) -- most complex heuristic | Large | Steps 2, 3 | `ConcurrencyIndexPass.swift` |
| 8 | Write tests for Rule 1 | Medium | Step 7 | `ConcurrencyIndexPassTests.swift` |
| 9 | Integrate Pass 2 into `ConcurrencyAuditor.check()` with graceful degradation | Small | Steps 3, 7 | `ConcurrencyAuditor.swift` |
| 10 | Add `IndexStoreInfra` dependency to ConcurrencyAuditor target | Small | Step 9 | `Package.swift` |
| 11 | Write graceful degradation tests | Small | Step 9 | `ConcurrencyIndexPassTests.swift` |
| 12 | Write DocC narrative article and update rule catalog | Medium | Steps 7, 9 | `ConcurrencyAuditor.docc/` |
| 13 | Quality gate: 0 errors / 0 warnings | Small | All above | -- |

Steps 1-2 are independent and can run in parallel. Steps 3-4 (Rule 2) and 5-6 (Rule 3) are sequential but can proceed before Step 7 (Rule 1). Total estimated effort: 3-4 sessions.

---

## Success Criteria

1. Pass 1 produces identical results to today -- no regressions on existing 8 rules
2. Pass 2 detects `@unchecked Sendable` types that never cross isolation boundaries (Rule 1)
3. Pass 2 detects mutable stored properties added via cross-file extensions on Sendable classes (Rule 2)
4. Pass 2 detects unnecessary `@preconcurrency import` annotations (Rule 3)
5. Missing index produces a single `.note` diagnostic, never an error or warning
6. `useIndexStore: false` disables Pass 2 entirely with no trace in output
7. `auditSource(_:fileName:configuration:)` (single-file mode) is unaffected
8. All new code is `Sendable`-compliant
9. Quality gate passes 0/0 after implementation
10. DocC narrative article renders correctly and covers all three rules with examples
