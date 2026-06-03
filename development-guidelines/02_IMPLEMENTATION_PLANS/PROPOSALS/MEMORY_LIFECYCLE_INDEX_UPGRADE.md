# Design Proposal: MemoryLifecycleGuard IndexStoreInfra Upgrade (Pass 2)

**Date:** 2026-06-03
**Context:** MemoryLifecycleGuard currently operates as a single-file SwiftSyntax visitor (`LifecycleVisitor`) with 5 rules across ~438 lines in 2 files. It detects Task properties without deinit/cancel, strong delegate references, unbounded AsyncStream creation, and loop-based memory growth. All analysis is confined to the file where the declaration appears.

**Motivation:** In real-world Swift codebases, lifecycle management frequently spans multiple files. A class declares a stored `Task` property in one file, but its `deinit` (with the `.cancel()` call) lives in an extension in a separate file. Similarly, delegate assignment and AsyncStream termination often occur in files other than where the property or stream is declared. This single-file limitation produces both false positives (flagging correctly-managed resources as violations) and false negatives (missing cross-file retention issues).

**Status:** Draft

---

## 1. Problem

MemoryLifecycleGuard's Pass 1 performs all analysis within the boundaries of a single source file. This creates three concrete gaps:

### 1.1 False Positives from Cross-File Task Cancellation

A common Swift pattern splits a class across files:

```swift
// DownloadManager.swift
class DownloadManager {
    var downloadTask: Task<Void, Never>?  // Pass 1 flags: lifecycle-task-no-cancel
    // ...
}
```

```swift
// DownloadManager+Lifecycle.swift
extension DownloadManager {
    deinit {
        downloadTask?.cancel()  // Cancellation exists — but Pass 1 can't see it
    }
}
```

Pass 1 sees `DownloadManager.swift` in isolation, finds a stored `Task` property, finds no `deinit` in the same file, and emits `lifecycle-task-no-deinit`. This is a false positive. The developer is correctly managing the Task lifecycle; they just organized it in a separate file.

The same false positive occurs when cancellation happens in a `tearDown()`, `stop()`, or `invalidate()` method defined in an extension file, rather than in `deinit` directly.

### 1.2 Cross-File Delegate Retention

Pass 1 detects strong delegate properties within a class declaration. However, it cannot detect a subtler problem: a `weak` delegate property that is assigned a strong reference in another file that captures and retains the delegate object beyond the expected scope.

```swift
// Coordinator.swift
class Coordinator {
    weak var delegate: CoordinatorDelegate?
}
```

```swift
// Setup.swift
func configure() {
    let coordinator = Coordinator()
    coordinator.delegate = self  // self is strongly retained by the calling object
    self.retainedCoordinator = coordinator  // creates a retain cycle
}
```

Pass 1 sees the `weak` modifier on `delegate` in `Coordinator.swift` and moves on. It cannot detect that the assignment site in `Setup.swift` creates a strong back-reference that defeats the `weak` annotation.

### 1.3 Cross-File Stream Termination

Pass 1 flags `AsyncStream.makeStream()` without `bufferingPolicy` as `lifecycle-unbounded-stream`. But a stream may be correctly terminated (via `continuation.finish()` or an `onTermination` handler) in a different file from where it was created:

```swift
// EventBus.swift
let (stream, continuation) = AsyncStream.makeStream(of: Event.self)  // Pass 1 flags this
```

```swift
// EventBus+Cleanup.swift
extension EventBus {
    func shutdown() {
        continuation.finish()  // Termination exists cross-file
    }
}
```

Pass 1 cannot see the `finish()` call and emits a false positive.

### Scale of the Problem

In a medium-sized SwiftUI app (e.g., 80+ source files with extension-heavy organization), these false positives can account for 30-50% of all MemoryLifecycleGuard diagnostics. Developers either suppress them with `// lifecycle:exempt` (losing real coverage) or disable the checker entirely.

## 2. Objective

Add an optional **Pass 2** to MemoryLifecycleGuard that uses IndexStoreInfra for cross-file analysis. Pass 2 runs after Pass 1 and produces four new diagnostic rules:

| Rule ID | Severity | Effect |
|---------|----------|--------|
| `lifecycle-task-cancel-in-extension` | info | Suppresses Pass 1's `lifecycle-task-no-cancel` or `lifecycle-task-no-deinit` false positive when cancellation exists in another file |
| `lifecycle-delegate-retained-elsewhere` | warning | Detects when a `weak` delegate property is assigned a strong reference in another file that outlives the expected scope |
| `lifecycle-stream-terminated-elsewhere` | info | Suppresses Pass 1's `lifecycle-unbounded-stream` false positive when the stream has a `finish()` call or `onTermination` handler in another file |
| `lifecycle-stale-exemption` | info | Suggests removal of a `// lifecycle:exempt` comment when IndexStoreDB shows the condition that originally required the exemption no longer exists |

Pass 2 follows the established dual-pass pattern (see `IndexStoreInfraUpgradeMap.md`): it is optional, gracefully degrades when the index is unavailable, and is controlled by a `useIndexStore` configuration toggle.

The new analysis lives in a single new file: `Sources/MemoryLifecycleGuard/LifecycleIndexPass.swift`.

## 3. Proposed Design

### 3.1 Dual-Pass Architecture

```
Pass 1 (Syntactic)                    Pass 2 (Cross-Module)
LifecycleVisitor.swift                LifecycleIndexPass.swift
per-file SwiftSyntax walk      →      IndexStoreDB queries
produces diagnostics                  produces additional diagnostics
always runs                           optional (requires index)
```

Pass 2 receives the diagnostics from Pass 1 as input, along with an `IndexStoreSession`. It queries the index to determine whether Pass 1 false positives should be suppressed and whether new cross-file issues should be flagged.

### 3.2 LifecycleIndexPass API

```swift
/// Cross-file lifecycle analysis powered by IndexStoreDB.
///
/// Runs after Pass 1 (LifecycleVisitor) to suppress false positives
/// where lifecycle management spans multiple files, and to detect
/// cross-file retention issues invisible to single-file analysis.
public struct LifecycleIndexPass: Sendable {

    /// Inputs gathered from Pass 1 that Pass 2 needs to analyze.
    public struct Inputs: Sendable {
        /// Pass 1 diagnostics that may contain false positives.
        let pass1Diagnostics: [Diagnostic]
        /// Task properties found during Pass 1, keyed by fully qualified type name.
        let taskProperties: [String: [TaskPropertyInfo]]
        /// Delegate properties found during Pass 1.
        let delegateProperties: [DelegatePropertyInfo]
        /// AsyncStream creation sites found during Pass 1.
        let streamCreationSites: [StreamCreationInfo]
        /// Existing `// lifecycle:exempt` markers found during Pass 1.
        let exemptionMarkers: [ExemptionMarkerInfo]
    }

    /// A stored Task property discovered by Pass 1.
    public struct TaskPropertyInfo: Sendable {
        let typeName: String
        let propertyName: String
        let filePath: String
        let line: Int
    }

    /// A delegate property discovered by Pass 1.
    public struct DelegatePropertyInfo: Sendable {
        let typeName: String
        let propertyName: String
        let isWeak: Bool
        let filePath: String
        let line: Int
    }

    /// An AsyncStream creation site discovered by Pass 1.
    public struct StreamCreationInfo: Sendable {
        let variableName: String?
        let filePath: String
        let line: Int
    }

    /// A `// lifecycle:exempt` comment marker discovered by Pass 1.
    public struct ExemptionMarkerInfo: Sendable {
        let suppressedRuleId: String
        let associatedDeclarationName: String
        let typeName: String?
        let filePath: String
        let line: Int
    }

    /// Runs cross-file lifecycle analysis.
    ///
    /// - Parameters:
    ///   - inputs: Data gathered from Pass 1.
    ///   - session: An open IndexStoreDB session.
    /// - Returns: Modified diagnostics (Pass 1 diagnostics with false positives
    ///   suppressed, plus any new cross-file diagnostics).
    public func run(inputs: Inputs, session: IndexStoreSession) -> [Diagnostic]
}
```

### 3.3 Rule: `lifecycle-task-cancel-in-extension`

**Trigger:** Pass 1 emitted `lifecycle-task-no-cancel` or `lifecycle-task-no-deinit` for a class with a stored `Task` property.

**Pass 2 logic:**
1. Look up the class by name in the IndexStoreDB using `canonicalOccurrences`.
2. Find all methods and deinitializers of that class across all files using `occurrences(ofUSR:roles: [.definition, .declaration])` filtered by `.childOf` relations.
3. For each method/deinit found in a file other than where the Task property is declared, read the source and check for `.cancel()` calls on the Task property name.
4. If cancellation is found in another file:
   - Remove the Pass 1 false positive (`lifecycle-task-no-cancel` or `lifecycle-task-no-deinit`)
   - Emit an info-level `lifecycle-task-cancel-in-extension` noting where cancellation was found

**Severity:** `info` -- this is a suppression notification, not a new warning.

### 3.4 Rule: `lifecycle-delegate-retained-elsewhere`

**Trigger:** Pass 1 found a `weak` delegate property (i.e., a property matching `delegatePatterns` that correctly has `weak`).

**Pass 2 logic:**
1. Look up the delegate property by USR in IndexStoreDB.
2. Find all write references (`roles: [.write]`) to the property across all files.
3. For each write site, examine the surrounding context:
   - Is the assigned value `self` or a property of `self`?
   - Is the assigning object retained by the same object that owns the delegate? (Check for stored property assignments in the same scope.)
4. If a strong back-reference pattern is detected, emit `lifecycle-delegate-retained-elsewhere`.

**Severity:** `warning` -- this is a genuine new finding that Pass 1 cannot detect.

**Heuristic limitation:** Full retain-cycle detection requires type-checked code analysis beyond what IndexStoreDB provides. Pass 2 uses conservative heuristics: it flags the pattern `obj.delegate = self` when `self` also holds a strong reference to `obj`. This catches the most common retain cycle pattern without requiring a full ownership graph.

### 3.5 Rule: `lifecycle-stream-terminated-elsewhere`

**Trigger:** Pass 1 emitted `lifecycle-unbounded-stream` for an `AsyncStream.makeStream()` call.

**Pass 2 logic:**
1. Identify the continuation variable name from the `makeStream()` destructuring pattern.
2. Search IndexStoreDB for all references to the continuation variable.
3. For each reference in a file other than the creation site, check if the reference is a `.finish()` call or an `onTermination` assignment.
4. If termination is found:
   - Remove the Pass 1 false positive (`lifecycle-unbounded-stream`)
   - Emit an info-level `lifecycle-stream-terminated-elsewhere` noting where termination was found

**Severity:** `info` -- this is a suppression notification, not a new warning.

### 3.6 Rule: `lifecycle-stale-exemption`

**Trigger:** Pass 2 encounters a `// lifecycle:exempt` comment marker on a declaration during analysis.

**Pass 2 logic:**
1. Scan source files for `// lifecycle:exempt` comment markers, collecting each marker's associated declaration (Task property, delegate property, or stream creation site) and the Pass 1 rule it suppresses.
2. For each exemption, use IndexStoreDB to check whether the condition that originally required the exemption has been resolved:
   - **Task exemptions:** Check if a `.cancel()` call on the Task property now exists somewhere in the codebase (in `deinit`, a teardown method, or any reachable call site).
   - **Delegate exemptions:** Check if the delegate property is now declared `weak`, or if the strong back-reference that created the retain cycle has been removed.
   - **Stream exemptions:** Check if a `continuation.finish()` call or `onTermination` handler now exists in the codebase.
3. If the condition that required the exemption no longer exists, emit an info-level `lifecycle-stale-exemption` diagnostic suggesting the exemption comment can be removed.

**Severity:** `info` -- this is a cleanup suggestion, not a warning. Stale exemptions are harmless but add noise and reduce code clarity. Surfacing them helps developers clean up suppressions that accumulated during development and are no longer needed.

**Rationale:** Over time, developers add `// lifecycle:exempt` comments to suppress false positives or to acknowledge known issues they plan to address later. When the underlying issue is fixed (e.g., a Task now has proper cancellation, a delegate is now weak), the exemption comment becomes stale. Without this rule, stale exemptions persist indefinitely, obscuring which exemptions are still genuinely needed. This rule closes the loop by proactively identifying suppressions that can be safely removed.

### 3.7 Orchestration in MemoryLifecycleGuard.swift

The `check(configuration:)` method gains Pass 2 orchestration:

```swift
public func check(configuration: Configuration) async throws -> CheckResult {
    // Pass 1: syntactic (always runs) — existing code
    var diagnostics = auditDirectory(at: sourcesPath, config: config)

    // Pass 2: cross-file (optional, requires IndexStoreDB)
    if config.useIndexStore {
        do {
            let session = try openIndexSession()
            let inputs = LifecycleIndexPass.Inputs(
                pass1Diagnostics: diagnostics,
                taskProperties: collectedTaskProperties,
                delegateProperties: collectedDelegateProperties,
                streamCreationSites: collectedStreamSites,
                exemptionMarkers: collectedExemptionMarkers
            )
            let pass2 = LifecycleIndexPass()
            diagnostics = pass2.run(inputs: inputs, session: session)
        } catch {
            // Graceful degradation: index unavailable, emit note
            diagnostics.append(Diagnostic(
                severity: .info,
                message: "IndexStoreDB unavailable; cross-file lifecycle analysis skipped (\(error.localizedDescription))",
                ruleId: "lifecycle-index-unavailable"
            ))
        }
    }

    // ... build CheckResult as before
}
```

### 3.8 Pass 1 Data Collection

To feed Pass 2, `LifecycleVisitor` must collect structured data (not just diagnostics) about the Task properties, delegate properties, and stream creation sites it encounters. Add three arrays to `LifecycleVisitor`:

```swift
private(set) var taskPropertyInfos: [LifecycleIndexPass.TaskPropertyInfo] = []
private(set) var delegatePropertyInfos: [LifecycleIndexPass.DelegatePropertyInfo] = []
private(set) var streamCreationInfos: [LifecycleIndexPass.StreamCreationInfo] = []
private(set) var exemptionMarkerInfos: [LifecycleIndexPass.ExemptionMarkerInfo] = []
```

These are populated alongside the existing diagnostic emission. Pass 1 behavior is unchanged -- the same diagnostics are emitted. The info arrays are only consumed if Pass 2 runs.

## 4. MCP Schema

Internal checker; no MCP schema required.

MemoryLifecycleGuard is invoked by the quality-gate CLI, not via MCP. Pass 2 adds no external API surface.

## 5. Constraints & Compliance

### Graceful Degradation

Pass 2 never fails the quality gate when the index is unavailable. The degradation sequence:

1. **No IndexStoreDB available** (e.g., Linux CI, missing Xcode toolchain): Pass 2 is skipped entirely. A single `info`-level diagnostic notes that cross-file analysis was unavailable.
2. **Stale index** (index store exists but is outdated): Pass 2 runs with available data. Results may be incomplete but will not produce false positives (suppression rules only remove Pass 1 diagnostics when evidence is found; they never add false confidence).
3. **Index query returns no results for a known type**: Pass 1 diagnostics are preserved unchanged. Pass 2 does not assume absence of index data means absence of the pattern.

### Configuration Toggle

```yaml
memoryLifecycle:
  useIndexStore: true  # default: true (use index when available)
  delegatePatterns: [delegate, parent, owner, dataSource]
  requireTaskCancellation: true
  exemptFiles: []
  heavyFrameworkTypes: [MLXArray, MTLBuffer, MTLTexture, CGImage, CGContext, CVPixelBuffer]
  loopGrowthExemptPatterns: []
```

When `useIndexStore` is `false`, Pass 2 is completely skipped with no performance cost.

### Concurrency & Sendability

- `LifecycleIndexPass` is a `Sendable` struct with no mutable state.
- `LifecycleIndexPass.Inputs` and its nested info types are all `Sendable`.
- `IndexStoreSession` is `@unchecked Sendable` (existing pattern; justified by single-task read-only access).
- Pass 2 runs synchronously within the checker's `async` context -- no additional concurrency concerns.

### Performance

Pass 2 adds IndexStoreDB queries proportional to the number of Pass 1 findings, not the number of source files. A typical project with 5-10 Task properties, 3-5 delegate properties, and 2-3 stream creation sites will issue ~20-30 index queries. IndexStoreDB queries are sub-millisecond for local stores; total Pass 2 overhead is expected to be under 50ms.

## 6. Backend / Compute

Not compute-intensive; no backend abstraction required.

All analysis runs locally using IndexStoreDB's on-disk index store. No network access, no GPU compute, no external service calls. The index store is generated by the Swift compiler during `swift build` and is read-only during analysis.

## 7. Dependencies

### Internal

| Dependency | Usage |
|-----------|-------|
| `IndexStoreInfra` | `IndexStoreSession` for database access, `ConformanceQuery.findReferences` for USR-based reference lookup, `StoreLocator` for finding the index store path, `ProjectKind` for project detection |
| `QualityGateCore` | `Diagnostic`, `CheckResult`, `Configuration`, `MemoryLifecycleConfig` |
| `SwiftSyntax` / `SwiftParser` | Existing Pass 1 dependency; Pass 2 may re-parse individual files to inspect call sites |

### External

No new external dependencies. `IndexStoreDB` is already a dependency of the `IndexStoreInfra` module.

### Package.swift Changes

Add `IndexStoreInfra` as a dependency of the `MemoryLifecycleGuard` target:

```swift
.target(
    name: "MemoryLifecycleGuard",
    dependencies: [
        "QualityGateCore",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        "IndexStoreInfra",  // NEW
    ]
),
```

### ConformanceQuery Additions

Pass 2 requires one new query helper in `ConformanceQuery` (identified in `IndexStoreInfraUpgradeMap.md`):

```swift
/// Check whether a type (by USR) has a method with the given name in any file.
public static func hasMethod(
    named methodName: String,
    in session: IndexStoreSession,
    ofType typeUSR: String
) -> Bool
```

This is shared infrastructure that will also benefit future ConcurrencyAuditor and RecursionAuditor upgrades.

## 8. Test Strategy

### New Test File

`Tests/MemoryLifecycleGuardTests/LifecycleIndexPassTests.swift`

### Test Cases

#### Cross-File Task Cancellation

| Test | Setup | Assertion |
|------|-------|-----------|
| `testTaskCancelInExtensionSuppressesFalsePositive` | Pass 1 emits `lifecycle-task-no-cancel`; mock index shows `.cancel()` in extension file | Pass 1 diagnostic removed; `lifecycle-task-cancel-in-extension` info emitted |
| `testTaskCancelInDeinitExtensionSuppressesFalsePositive` | Pass 1 emits `lifecycle-task-no-deinit`; mock index shows `deinit` with `.cancel()` in extension file | Pass 1 diagnostic removed; `lifecycle-task-cancel-in-extension` info emitted |
| `testTaskNoCancelAnywherePersistsDiagnostic` | Pass 1 emits `lifecycle-task-no-cancel`; mock index shows no `.cancel()` in any file | Pass 1 diagnostic preserved unchanged |
| `testTaskCancelInSameFileNotDoubleCounted` | Pass 1 does NOT emit (cancel exists in same file); mock index also sees it | No diagnostic emitted (Pass 2 has nothing to do) |

#### Delegate Retention

| Test | Setup | Assertion |
|------|-------|-----------|
| `testDelegateRetainedElsewhereEmitsWarning` | `weak var delegate` in class; mock index shows `obj.delegate = self` where `self` retains `obj` | `lifecycle-delegate-retained-elsewhere` warning emitted |
| `testDelegateAssignedWithoutRetainCycleNoWarning` | `weak var delegate` in class; mock index shows assignment without back-reference | No new diagnostic |
| `testStrongDelegateAlreadyFlaggedByPass1` | Pass 1 flags `lifecycle-strong-delegate`; mock index shows assignment | Pass 1 diagnostic preserved; no duplicate from Pass 2 |

#### Stream Termination

| Test | Setup | Assertion |
|------|-------|-----------|
| `testStreamFinishElsewhereSuppressesFalsePositive` | Pass 1 emits `lifecycle-unbounded-stream`; mock index shows `continuation.finish()` in another file | Pass 1 diagnostic removed; `lifecycle-stream-terminated-elsewhere` info emitted |
| `testStreamOnTerminationElsewhereSuppressesFalsePositive` | Pass 1 emits `lifecycle-unbounded-stream`; mock index shows `onTermination` assignment in another file | Pass 1 diagnostic removed; `lifecycle-stream-terminated-elsewhere` info emitted |
| `testStreamNoTerminationAnywherePersistsDiagnostic` | Pass 1 emits `lifecycle-unbounded-stream`; mock index shows no termination | Pass 1 diagnostic preserved unchanged |

#### Stale Exemption Cleanup

| Test | Setup | Assertion |
|------|-------|-----------|
| `testStaleTaskExemptionDetected` | `// lifecycle:exempt` on a Task property; mock index shows `.cancel()` now exists elsewhere in codebase | `lifecycle-stale-exemption` info emitted suggesting removal |
| `testStaleDelegateExemptionDetected` | `// lifecycle:exempt` on a delegate property; mock index shows delegate is now `weak` | `lifecycle-stale-exemption` info emitted suggesting removal |
| `testStaleStreamExemptionDetected` | `// lifecycle:exempt` on a stream creation; mock index shows `continuation.finish()` now exists | `lifecycle-stale-exemption` info emitted suggesting removal |
| `testValidExemptionNotFlagged` | `// lifecycle:exempt` on a Task property; mock index shows no `.cancel()` anywhere | No `lifecycle-stale-exemption` diagnostic emitted |

#### Graceful Degradation

| Test | Setup | Assertion |
|------|-------|-----------|
| `testIndexUnavailableEmitsInfoAndPreservesDiagnostics` | Pass 1 produces diagnostics; IndexStoreSession creation throws | All Pass 1 diagnostics preserved; one `lifecycle-index-unavailable` info appended |
| `testIndexEmptyReturnsPreservesDiagnostics` | Pass 1 produces diagnostics; index queries return empty results | All Pass 1 diagnostics preserved unchanged (no suppression without evidence) |
| `testUseIndexStoreFalseSkipsPass2` | `config.useIndexStore = false` | Pass 2 never executes; no info diagnostic emitted |

### Testing Approach

Tests use mock/stub `IndexStoreSession` data rather than requiring a real index store. This ensures tests are fast, deterministic, and runnable in CI without Xcode. The mock layer injects predetermined query results for specific USRs.

Integration testing against a real index store is deferred to a manual validation step against a multi-file Swift project (e.g., quality-gate-swift itself).

## 9. Open Questions

1. **Should Pass 2 also track `AnyCancellable` / Combine subscriptions?** Combine's `AnyCancellable` has the same lifecycle pattern as `Task` -- it should be cancelled or stored in a `Set<AnyCancellable>` that is cleared in `deinit`. Pass 1 does not currently check Combine patterns. Adding Combine tracking to Pass 2 would extend the scope significantly (new Pass 1 rules + Pass 2 cross-file validation). **Resolved:** Write a separate proposal for Combine/AnyCancellable lifecycle tracking. The Task lifecycle rules in this proposal establish the dual-pass pattern and shared infrastructure; Combine rules will follow the same architecture. If the separate proposal identifies infrastructure that must be integrated during this phase (e.g., shared cancellation-query helpers), that infrastructure will be built here. Otherwise, Combine tracking is purely additive and can be built later.

2. **Should Pass 2 detect retain cycles via IndexStoreDB?** Full retain-cycle detection (A holds B, B holds A) requires constructing an ownership graph from all stored property types and their reference semantics (class vs. struct, weak vs. strong). IndexStoreDB provides the reference data, but building a correct ownership graph is a substantially larger undertaking than the four targeted rules in this proposal. **Resolved:** Write a separate proposal for general retain-cycle detection via IndexStoreDB. The `lifecycle-delegate-retained-elsewhere` rule in this proposal covers the most common retain cycle pattern (delegate back-references) and validates the IndexStoreDB query infrastructure. A general retain-cycle detector deserves its own proposal with dedicated scope, ownership-graph design, and test strategy.

3. **Should suppressed Pass 1 diagnostics be reported at all?** When Pass 2 determines a Pass 1 diagnostic is a false positive, should it be silently removed or replaced with an info-level note? **Resolved:** Replace suppressed Pass 1 diagnostics with info-level notes (`lifecycle-task-cancel-in-extension`, `lifecycle-stream-terminated-elsewhere`). This provides an audit trail and lets developers verify that Pass 2 is correctly analyzing their code. The info diagnostics do not affect the gate status and can be filtered out with severity overrides.

## 10. Documentation Strategy

**Documentation Type:** API Docs Only

**Complexity Threshold Check:**
- Does it combine 3+ APIs? No -- single `LifecycleIndexPass.run(inputs:session:)` entry point
- Does explanation require 50+ lines? No
- Does it need theory/background context? No

**Scope:**
- Add doc comments to `LifecycleIndexPass`, its `Inputs` struct, and the `run(inputs:session:)` method
- Update the module-level DocC comment in `MemoryLifecycleGuard.swift` to mention Pass 2 and the four new rules
- Update the `MemoryLifecycleGuard.docc` catalog to list the new rule IDs

This is simpler scope than ConcurrencyAuditor's documentation needs. MemoryLifecycleGuard is an internal checker with no public MCP surface; API doc comments are sufficient.

---

## Modified Files Summary

| File | Change |
|------|--------|
| `Sources/MemoryLifecycleGuard/LifecycleIndexPass.swift` | **NEW** -- Pass 2 cross-file analysis logic |
| `Sources/MemoryLifecycleGuard/MemoryLifecycleGuard.swift` | Add Pass 2 orchestration after Pass 1 |
| `Sources/MemoryLifecycleGuard/LifecycleVisitor.swift` | Collect structured info arrays alongside diagnostics for Pass 2 consumption |
| `Sources/QualityGateCore/Configuration.swift` | Add `useIndexStore: Bool` to `MemoryLifecycleConfig` |
| `Sources/IndexStoreInfra/ConformanceQuery.swift` | Add `hasMethod(named:in:ofType:)` query helper |
| `Package.swift` | Add `IndexStoreInfra` dependency to `MemoryLifecycleGuard` target |
| `Tests/MemoryLifecycleGuardTests/LifecycleIndexPassTests.swift` | **NEW** -- Pass 2 test coverage |

## Implementation Sequence

Following TDD workflow:

1. **RED:** Write `LifecycleIndexPassTests.swift` with all test cases -- they will fail because Pass 2 does not exist yet
2. **GREEN:**
   a. Add `useIndexStore` to `MemoryLifecycleConfig` in `Configuration.swift`
   b. Add info collection arrays to `LifecycleVisitor`
   c. Create `LifecycleIndexPass.swift` with the four rules
   d. Add `hasMethod(named:in:ofType:)` to `ConformanceQuery`
   e. Wire Pass 2 into `MemoryLifecycleGuard.check(configuration:)`
   f. Add `IndexStoreInfra` dependency in `Package.swift`
3. **REFACTOR:** Extract shared USR lookup and source-reading helpers
4. **VERIFY:** Run quality gate on quality-gate-swift itself; confirm 0/0

---

**Author:** Justin Purnell + Claude Opus 4.6
