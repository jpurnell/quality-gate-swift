# Design Proposal: ComplexityAnalyzer IndexStoreDB Upgrade

**Date:** 2026-06-03
**Author:** Justin Purnell + Claude Opus 4.6
**Status:** Proposed
**Parent:** [IndexStoreInfra Upgrade Map](IndexStoreInfraUpgradeMap.md) -- Tier 2, Phase 5

---

## 1. Objective

The ComplexityAnalyzer already computes per-function cognitive complexity, cyclomatic complexity, and Big-O estimates, with intra-module call graph amplification via `CallGraphBuilder` and `CallGraphAmplifier`. However, the call graph is limited in two ways:

1. **Name-based resolution** -- `CallGraphBuilder` matches calls to defined functions by name (`definedFunctions.contains(calleeName)`). When two functions share the same name (overloads), all are treated as the same callee, producing inflated or incorrect amplified complexity.

2. **Intra-module scope** -- The call graph only resolves calls to functions defined in the same source string. A function with cognitive complexity 5 that delegates to a function in another module with complexity 20 reports complexity 5 -- hiding the effective cost from the developer.

Cross-module amplification catches hidden complexity delegation. A function that appears simple but forwards to deeply complex code in another module is effectively complex -- its maintenance burden, bug surface area, and cognitive load on reviewers scale with the transitive call chain, not just its local body. Without cross-module resolution, the ComplexityAnalyzer understates effective complexity for any project with meaningful module decomposition.

**Master Plan Reference:** Extends Phase 2 complexity analysis with Phase 4 IndexStoreDB integration.

---

## 2. Proposed Architecture

The upgrade follows the **optional Pass 2** pattern established by UnreachableCodeAuditor and documented in the IndexStoreInfra Upgrade Map:

```
Pass 1 (Syntactic)          Pass 2 (Cross-Module)
   always runs                 optional, requires IndexStoreDB
   per-file analysis           cross-module call graph
   existing behavior           amplified complexity
         │                              │
         ▼                              ▼
   FunctionComplexityRecord     FunctionComplexityRecord
   (local complexity only)      (+ amplifiedCognitiveComplexity)
```

### Pass 1 (unchanged)

Existing per-file cognitive/cyclomatic/BigO analysis via `CognitiveComplexityVisitor`, `BigOEstimator`, `PatternDetector`, and optional intra-module `CallGraphAmplifier`. Produces `[FunctionComplexityRecord]` exactly as today. No code changes to Pass 1.

### Pass 2 (new -- ComplexityIndexPass)

When IndexStoreDB is available and `useIndexStore` is `true`:

1. **Build USR-indexed function map** -- For each `FunctionComplexityRecord` from Pass 1, use `ConformanceQuery.symbolsInFiles` to obtain the USR for each function declaration. Build a `[String: FunctionComplexityRecord]` keyed by USR.

2. **Resolve cross-module callees** -- For each function USR, use `ConformanceQuery.findReferences(toUSR:in:roles: [.call])` to find all call sites. For each call site, look up the callee's USR. If the callee's USR maps to a `FunctionComplexityRecord` in a *different* module, record the cross-module edge.

3. **Compute amplified cognitive complexity** -- Walk the cross-module call graph (respecting `crossModuleMaxDepth`) and sum cognitive complexities along the call chain. A function with local complexity 5 calling a cross-module function with complexity 20 gets amplified complexity 25.

4. **Emit diagnostics** -- For functions where amplified complexity exceeds the cognitive threshold but local complexity does not, emit a `complexity.cross-module-amplification` warning.

### Graceful degradation

If IndexStoreDB is unavailable (no index store found, `libIndexStore` not installed, stale index), Pass 2 emits a single `.note` diagnostic and returns the Pass 1 results unchanged. The gate never fails due to missing index infrastructure.

### New files

| File | Purpose |
|------|---------|
| `Sources/ComplexityAnalyzer/ComplexityIndexPass.swift` | Pass 2 orchestration: USR resolution, cross-module call graph, amplified complexity computation |

### Modified files

| File | Change |
|------|--------|
| `Sources/ComplexityAnalyzer/ComplexityAnalyzer.swift` | Add Pass 2 invocation after Pass 1 in `check(configuration:)` and `scanProject(configuration:)` |
| `Sources/ComplexityAnalyzer/ComplexityModels.swift` | Add `amplifiedCognitiveComplexity: Int?` and `crossModuleCallees: [CrossModuleCallEdge]` to `FunctionComplexityRecord`; add `CrossModuleCallEdge` type; add `ComplexityBasis.crossModuleCognitiveAmplification` case |
| `Sources/QualityGateCore/Configuration.swift` | Add `useIndexStore: Bool`, `crossModuleAmplification: Bool`, `crossModuleMaxDepth: Int`, and `amplifiedCognitiveThreshold: Int` to `ComplexityAnalyzerConfig` |
| `Package.swift` | Add `IndexStoreInfra` dependency to `ComplexityAnalyzer` target |

---

## 3. API Surface

### ComplexityIndexPass (new)

```swift
/// Cross-module complexity amplification using IndexStoreDB.
///
/// Pass 2 of the ComplexityAnalyzer pipeline. Requires an active
/// IndexStoreSession. Falls back gracefully when unavailable.
public struct ComplexityIndexPass: Sendable {

    /// Inputs for the cross-module amplification pass.
    public struct Inputs: Sendable {
        /// Per-function complexity records from Pass 1.
        public let records: [FunctionComplexityRecord]
        /// Active IndexStoreDB session.
        public let session: IndexStoreSession
        /// Maximum transitive call depth for cross-module resolution.
        /// User-configurable with no hard cap. Depths > 3 emit a
        /// performance warning but still execute.
        public let crossModuleMaxDepth: Int
        /// Cognitive complexity threshold for local complexity.
        public let cognitiveThreshold: Int
        /// Separate threshold for amplified cross-module complexity (default: 30).
        public let amplifiedCognitiveThreshold: Int
        /// Per-module threshold overrides.
        public let moduleThresholds: [String: Int]
    }

    /// Result of the cross-module amplification pass.
    public struct Output: Sendable {
        /// Updated records with amplified complexity where applicable.
        public let records: [FunctionComplexityRecord]
        /// Diagnostics for functions exceeding threshold only via amplification.
        public let diagnostics: [Diagnostic]
    }

    /// Runs cross-module complexity amplification.
    ///
    /// - Parameter inputs: Pass 1 records and IndexStoreDB session.
    /// - Returns: Amplified records and cross-module diagnostics.
    public static func run(inputs: Inputs) -> Output
}
```

### CrossModuleCallEdge (new model)

```swift
/// A directed edge in the cross-module call graph, resolved by USR.
public struct CrossModuleCallEdge: Sendable, Codable, Equatable {
    /// USR of the calling function.
    public let callerUSR: String
    /// USR of the called function.
    public let calleeUSR: String
    /// Human-readable name of the callee.
    public let calleeName: String
    /// Module containing the callee.
    public let calleeModule: String
    /// Cognitive complexity of the callee.
    public let calleeCognitiveComplexity: Int
    /// Whether the call occurs inside a loop in the caller.
    public let insideLoop: Bool
    /// Source line of the call site.
    public let line: Int
}
```

### FunctionComplexityRecord additions

```swift
public struct FunctionComplexityRecord {
    // ... existing fields ...

    /// Cognitive complexity amplified by cross-module call targets.
    /// nil when cross-module analysis is unavailable or not applicable.
    public let amplifiedCognitiveComplexity: Int?

    /// Cross-module callees resolved via IndexStoreDB.
    public let crossModuleCallees: [CrossModuleCallEdge]
}
```

### Configuration additions

```swift
public struct ComplexityAnalyzerConfig {
    // ... existing fields ...

    /// Whether to use IndexStoreDB for cross-module analysis (default: true).
    public let useIndexStore: Bool

    /// Whether to compute amplified cognitive complexity across module
    /// boundaries (default: true). Requires useIndexStore.
    public let crossModuleAmplification: Bool

    /// Maximum transitive call depth for cross-module resolution (default: 1).
    /// User-configurable with no hard cap. Depths exceeding 3 emit a
    /// performance warning but still execute. Higher values increase query
    /// volume multiplicatively -- appropriate for small/medium projects but
    /// may slow analysis on large codebases with thousands of functions.
    public let crossModuleMaxDepth: Int

    /// Separate cognitive complexity threshold for cross-module amplified
    /// complexity (default: 30). The cross-module warning fires only when
    /// amplified complexity exceeds this threshold AND local complexity
    /// does not exceed `cognitiveThreshold`.
    public let amplifiedCognitiveThreshold: Int
}
```

### New diagnostic rule

| Rule ID | Severity | Message Template |
|---------|----------|-----------------|
| `complexity.cross-module-amplification` | `.warning` | `"{functionName} has local cognitive complexity {local} but amplified complexity {amplified} via cross-module calls (threshold: {threshold})"` |
| `complexity.cross-module-depth-warning` | `.note` | `"crossModuleMaxDepth is set to {depth} (> 3); cross-module analysis may be slow on large codebases"` |

---

## 4. MCP Schema

Internal checker; no MCP schema required.

---

## 5. Constraints & Compliance

### Graceful degradation

Pass 2 is advisory-only. When the index is unavailable, the ComplexityAnalyzer produces identical results to today:

| Condition | Behavior |
|-----------|----------|
| No index store found | `.note`: "Cross-module complexity analysis skipped: index store not found" |
| `libIndexStore.dylib` not found | `.note`: "Cross-module complexity analysis skipped: libIndexStore not found" |
| Stale index (older than source files) | `.note`: "Cross-module complexity analysis may be stale: index older than source" |
| `useIndexStore: false` in config | Pass 2 skipped silently |
| `crossModuleAmplification: false` | Pass 2 skipped silently |

Falls back to intra-module call graph (existing `CallGraphAmplifier` behavior) in all degraded cases.

### Concurrency

- `ComplexityIndexPass` is a stateless value type (`Sendable`).
- `IndexStoreSession` is `@unchecked Sendable` with existing justification (single-task read-only queries).
- `CrossModuleCallEdge` and all new model types are value types conforming to `Sendable`.

### Swift 6 compliance

No new concurrency concerns. All IndexStoreDB queries are synchronous within the checker's `check()` method, matching the UnreachableCodeAuditor pattern.

### Backward compatibility

- `amplifiedCognitiveComplexity` defaults to `nil` (no change to existing records).
- `crossModuleCallees` defaults to `[]` (no change to existing records).
- `useIndexStore` defaults to `true` (opt-out, not opt-in -- matches UnreachableCodeAuditor convention).
- `crossModuleAmplification` defaults to `true`.
- `crossModuleMaxDepth` defaults to `1` (direct calls only). No hard cap; depths > 3 emit a performance warning.
- `amplifiedCognitiveThreshold` defaults to `30`.
- Existing YAML configurations without the new keys decode to defaults.

### Pass 1 isolation

Pass 2 never modifies Pass 1 diagnostic output. It only appends new `complexity.cross-module-amplification` diagnostics and populates the `amplifiedCognitiveComplexity` / `crossModuleCallees` fields. A project that clears the gate today will still clear it after this upgrade (cross-module amplification diagnostics are `.warning`, not `.error`, by default).

---

## 6. Backend Abstraction

Not compute-intensive; no backend abstraction required.

IndexStoreDB queries are I/O-bound (memory-mapped database reads), not CPU-bound. The cross-module call graph is bounded by `crossModuleMaxDepth` (default 1, meaning direct calls only). Even with `maxDepth: 3` on a project with 50 modules and 5,000 functions, the query volume is manageable (thousands of USR lookups, each sub-millisecond). Depths exceeding 3 emit a performance warning but still execute -- the user controls the trade-off via `crossModuleMaxDepth`.

---

## 7. Dependencies

### Internal

| Dependency | Usage |
|-----------|-------|
| `IndexStoreInfra` | `IndexStoreSession`, `ConformanceQuery`, `StoreLocator`, `ProjectKind` |
| `QualityGateCore` | `Configuration`, `Diagnostic`, `CheckResult` (existing) |
| `SwiftSyntax` / `SwiftParser` | Existing -- no new usage in Pass 2 |

### External

| Dependency | Notes |
|-----------|-------|
| `IndexStoreDB` | Transitive via `IndexStoreInfra` (already in the dependency graph) |

### Package.swift change

Add `IndexStoreInfra` to the ComplexityAnalyzer target's dependencies:

```swift
.target(
    name: "ComplexityAnalyzer",
    dependencies: [
        "QualityGateCore",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        "IndexStoreInfra",  // NEW
    ]
),
```

---

## 8. Test Strategy

### Test categories

**Cross-module amplification:**

| Test | Setup | Assertion |
|------|-------|-----------|
| `crossModuleAmplification_addsCalleeCognitiveComplexity` | Function A (complexity 5) calls Function B (complexity 20, different module) | `amplifiedCognitiveComplexity == 25` |
| `crossModuleAmplification_insideLoop_multipliesComplexity` | Function A (complexity 3) calls Function B (complexity 10) inside a `for` loop | `amplifiedCognitiveComplexity >= 13` (3 + 10 * loop factor) |
| `crossModuleAmplification_transitiveDepth2` | A calls B (module X), B calls C (module Y), maxDepth=2 | Amplified complexity includes C's contribution |
| `crossModuleAmplification_respectsMaxDepth` | Same chain, maxDepth=1 | Amplified complexity includes B only, not C |
| `crossModuleAmplification_emitsDiagnosticWhenExceedsThreshold` | Local=5, amplified=25, threshold=15 | `complexity.cross-module-amplification` warning emitted |
| `crossModuleAmplification_noDiagnosticWhenLocalExceedsThreshold` | Local=20, amplified=25, threshold=15 | Only `complexity.cognitive-threshold` note (existing), no redundant cross-module warning |
| `crossModuleAmplification_noDiagnosticWhenBelowThreshold` | Local=5, amplified=10, threshold=15 | No diagnostic |

**USR vs name resolution:**

| Test | Setup | Assertion |
|------|-------|-----------|
| `usrResolution_distinguishesOverloads` | `func process(_ x: Int)` (complexity 3) and `func process(_ x: String)` (complexity 15); caller calls `process(Int)` | Amplified complexity uses 3, not 15 |
| `usrResolution_matchesCrossModuleByUSR` | Function in module A calls function in module B by USR, not name | Cross-module edge correctly resolved |

**Depth limits:**

| Test | Setup | Assertion |
|------|-------|-----------|
| `depthLimit_zeroCutsOffAllCrossModule` | maxDepth=0 | `amplifiedCognitiveComplexity == nil` |
| `depthLimit_cyclicCallGraphTerminates` | A calls B, B calls A (cross-module) | No infinite loop; amplification uses visited-set |
| `depthLimit_largeGraphCompletesInTime` | 100 functions across 10 modules, maxDepth=3 | Completes in < 2 seconds |

**Graceful degradation:**

| Test | Setup | Assertion |
|------|-------|-----------|
| `degradation_noIndexStoreEmitsNote` | No IndexStoreSession available | Single `.note` diagnostic, records unchanged from Pass 1 |
| `degradation_useIndexStoreFalseSkipsSilently` | `useIndexStore: false` | No `.note`, no Pass 2, records unchanged |
| `degradation_crossModuleAmplificationFalseSkipsSilently` | `crossModuleAmplification: false` | Pass 2 skipped, records unchanged |
| `degradation_pass1ResultsUnchanged` | Any degradation scenario | Pass 1 diagnostics identical before and after |

### Test files

| File | Content |
|------|---------|
| `Tests/ComplexityAnalyzerTests/ComplexityIndexPassTests.swift` | Unit tests for `ComplexityIndexPass.run(inputs:)` with mock IndexStoreSession |
| `Tests/ComplexityAnalyzerTests/CrossModuleAmplificationTests.swift` | Integration tests using `CrossModuleFixture` (shared with UnreachableCodeAuditor) |

### Validation trace

Given module A with:
```swift
func orchestrate(items: [Item]) -> [Result] {  // cognitive complexity: 5
    items.map { item in
        transform(item)  // calls module B
    }
}
```

And module B with:
```swift
func transform(_ item: Item) -> Result {  // cognitive complexity: 18
    if item.isValid {                     // +1
        switch item.type {                // +2 (nesting)
            case .alpha:                  // +1
                if item.priority > 5 {    // +3 (nesting)
                    // ... complex logic
                }
            case .beta:                   // +1
                guard item.count > 0 else { // +3 (nesting)
                    return .empty
                }
                for sub in item.children { // +3 (nesting)
                    if sub.isActive {      // +4 (nesting)
                        // ...
                    }
                }
            default: break
        }
    }
}
```

Expected: `orchestrate` has local cognitive complexity 5, amplified cognitive complexity 23 (5 + 18 from cross-module callee). Diagnostic emitted: `"orchestrate has local cognitive complexity 5 but amplified complexity 23 via cross-module calls (threshold: 15)"`.

---

## 9. Open Questions

1. **Should cross-module amplification use a separate threshold?**

   The existing `cognitiveThreshold` (default 15) applies to local complexity. Cross-module amplified complexity will almost always be higher than local. Should there be a separate `amplifiedCognitiveThreshold` (e.g., default 30) to avoid noisy warnings on functions that are locally simple but call moderately complex cross-module code?

   **Recommendation:** Yes. Add `amplifiedCognitiveThreshold: Int` (default 30) to `ComplexityAnalyzerConfig`. The cross-module warning fires only when amplified exceeds this separate threshold AND local does not exceed `cognitiveThreshold`. This keeps the signal meaningful -- you only hear about it when the local view is misleading.

   **Resolved: Yes, default 30.** Separate `amplifiedCognitiveThreshold` with default value of 30. The cross-module warning fires only when amplified complexity exceeds this threshold AND local complexity does not exceed `cognitiveThreshold`.

2. **Performance concerns with deep call graphs across many modules?**

   With `callGraphMaxDepth: 1` (the default), Pass 2 performs one round of USR lookups per function. At depth 2+, the query count grows multiplicatively. For a project with 5,000 functions and depth 3, this could mean 50,000+ IndexStoreDB queries.

   **Recommendation:** Cap `callGraphMaxDepth` at 3 for cross-module analysis (even if a higher value is configured for intra-module). Add a performance note to the configuration documentation. If real-world timings show concern, add a budget-based cutoff (e.g., stop cross-module resolution after 5 seconds).

   **Resolved: No hard cap.** `crossModuleMaxDepth` is a user-configurable integer with no enforced ceiling. Depths exceeding 3 emit a performance warning but the analysis still executes. The rationale is that small, deeply nested programs are fine at high depth -- the concern is the combination of large codebases and high depth, not deeply nested programming styles. Users should be informed, not blocked.

3. **Should USR-based resolution replace name-based for intra-module too?**

   The existing `CallGraphBuilder` uses name matching. USR-based matching would eliminate overload false positives in intra-module analysis as well (same benefit as the RecursionAuditor USR upgrade).

   **Recommendation:** Yes, but as a follow-up. The RecursionAuditor USR upgrade (Phase 2 in the IndexStoreInfra Upgrade Map) will establish the pattern for USR-based intra-module call resolution. ComplexityAnalyzer can adopt the same approach after that ships. For this proposal, USR resolution is cross-module only; intra-module retains name-based matching as a fallback.

   **Resolved: Do it now, not deferred.** Implement RecursionAuditor's USR-based call graph first, then adopt it in ComplexityAnalyzer. USR-based resolution replaces name-based matching for intra-module analysis as part of this work, sequenced after the RecursionAuditor USR upgrade ships.

---

## 10. Documentation Strategy

**Documentation Type:** API Docs Only

This feature extends the existing documented ComplexityAnalyzer with an optional Pass 2. The user-facing surface is two new configuration keys (`useIndexStore`, `crossModuleAmplification`) and one new diagnostic rule (`complexity.cross-module-amplification`).

**Complexity Threshold Check:**
- Does it combine 3+ APIs? No -- single new pass with two config keys
- Does explanation require 50+ lines? No -- "enable IndexStoreDB for cross-module complexity"
- Does it need theory/background context? No -- extends existing call graph feature

**Documentation updates:**
- DocC comments on `ComplexityIndexPass`, `CrossModuleCallEdge`, and new `FunctionComplexityRecord` fields
- YAML example in `ComplexityAnalyzerConfig` doc comment showing `useIndexStore` and `crossModuleAmplification`
- Update CHANGELOG.md with new rule and configuration keys

---

## Implementation Sequence

Following TDD workflow per `09_TEST_DRIVEN_DEVELOPMENT.md`:

| Phase | Step | Description |
|-------|------|-------------|
| RED | 1 | Write `ComplexityIndexPassTests.swift` with all cross-module amplification and degradation tests -- they will fail because `ComplexityIndexPass` does not exist |
| GREEN | 2a | Add `CrossModuleCallEdge` and `amplifiedCognitiveComplexity` to `ComplexityModels.swift` |
| GREEN | 2b | Add `useIndexStore` and `crossModuleAmplification` to `ComplexityAnalyzerConfig` in `Configuration.swift` |
| GREEN | 2c | Add `IndexStoreInfra` dependency to `Package.swift` |
| GREEN | 2d | Implement `ComplexityIndexPass.swift` with USR resolution and amplified complexity computation |
| GREEN | 2e | Wire Pass 2 into `ComplexityAnalyzer.check(configuration:)` |
| GREEN | 2f | Adopt RecursionAuditor's USR-based call graph for intra-module resolution (replaces name-based `CallGraphBuilder` matching) |
| REFACTOR | 3 | Extract shared USR-resolution utilities (shared between RecursionAuditor and ComplexityAnalyzer) |
| VERIFY | 4 | Run quality gate -- target 0 errors, 0 warnings |

---

## Related Documents

- [IndexStoreInfra Upgrade Map](IndexStoreInfraUpgradeMap.md) -- Parent mapping document
- [RecursionAuditor Index Upgrade](RECURSION_AUDITOR_INDEX_UPGRADE.md) -- USR-based call graph for RecursionAuditor (Phase 2, shares `callees(of:in:)` infrastructure)
- [Checker Development Guide](../../03_REFERENCE/CHECKER_DEVELOPMENT_GUIDE.md) -- Protocol and patterns
- [Design Proposal Phase](../../00_CORE_RULES/05_DESIGN_PROPOSAL.md) -- Template reference
- [Test-Driven Development](../../00_CORE_RULES/09_TEST_DRIVEN_DEVELOPMENT.md) -- TDD workflow
