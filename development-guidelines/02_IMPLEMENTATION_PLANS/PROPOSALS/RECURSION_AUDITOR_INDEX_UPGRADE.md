# Design Proposal: RecursionAuditor IndexStoreDB USR Upgrade

**Date:** 2026-06-03
**Status:** Draft
**Author:** Justin Purnell + Claude Opus 4.6
**Parent:** `IndexStoreInfraUpgradeMap.md` (Tier 1 -- Phase 2)

---

## 1. Problem

The RecursionAuditor's project-wide mutual cycle detection (rule 8: `recursion.mutual-cycle`) builds its call graph using string-based `Signature` matching, where each declaration is keyed by `typeContext + displayName` (e.g., `"Parser.parse(input:)"`). This approach has three structural accuracy problems:

**1a. Overloaded functions produce false positives.** When two methods share a name and argument labels but differ in parameter types, the name-based graph treats them as the same node. A call from `process(input:)` taking `String` to `process(input:)` taking `Data` appears as a self-cycle even though the compiler resolves them to distinct symbols:

```swift
struct Converter {
    func process(input: String) -> Data {
        process(input: Data(input.utf8))  // Calls the Data overload, not self
    }
    func process(input: Data) -> Data { ... }
}
```

Current result: `recursion.mutual-cycle` warning on both overloads. Correct result: no diagnostic.

**1b. Same-named methods on unrelated types are conflated.** The graph uses `typeContext` from lexical scope, but when a method on type A calls a method with the same display name on type B through a local variable (not a constructor expression), the heuristic cannot resolve the receiver type. The `collectCalls` helper generates candidate signatures for the enclosing type context and empty context, potentially matching an unrelated declaration:

```swift
struct Logger {
    func write(message:) { ... }
}
struct FileWriter {
    func write(message:) {
        let logger = Logger()
        logger.write(message: msg)  // Receiver type unresolvable from syntax alone
    }
}
```

Current result: potential false positive cycle between `Logger.write(message:)` and `FileWriter.write(message:)`. Correct result: no cycle.

**1c. Cross-module calls are invisible.** The current architecture only walks `Sources/` in the local project. If module A calls a function in module B that calls back into module A, the cycle is undetectable because module B's source may not be under `Sources/` (it may be a dependency with compiled index data only). IndexStoreDB resolves cross-module USRs natively.

**Scale of the problem:** In the quality-gate-swift codebase itself (22 checker modules, ~35,000 LOC), the name-based call graph produces 3 false positive cycle warnings from overloaded diagnostic helper methods. In projects with heavy protocol-oriented design (common in Swift), the false positive rate scales with the number of protocol extensions using common method names like `validate()`, `process()`, `handle()`.

---

## 2. Proposed Architecture

### Design Principle: Dual-Pass with Graceful Degradation

Following the established IndexStoreInfra integration pattern (see `IndexStoreInfraUpgradeMap.md`), the upgrade adds an optional Pass 2 that runs only when IndexStoreDB is available. Pass 1 (per-file syntactic analysis) is unchanged.

```
┌─────────────────────────────────────────────────┐
│  Pass 1: Per-File Syntactic Analysis            │
│  (unchanged — RecursionVisitor)                 │
│                                                 │
│  Rules 1-7: unconditional-self-call,            │
│  protocol-extension-default-self,               │
│  convenience-init-self, computed-property-self,  │
│  setter-self, subscript-self,                   │
│  subscript-setter-self                          │
└────────────────┬────────────────────────────────┘
                 │ always runs
                 ▼
┌─────────────────────────────────────────────────┐
│  Pass 2: USR-Based Cross-File Cycle Detection   │
│  (NEW — RecursionIndexPass)                     │
│                                                 │
│  Rule 8 (upgraded): mutual-cycle via USR graph  │
│  Rule 9 (new): cross-module-cycle               │
│  Rule 10 (new): protocol-witness-cycle          │
└────────────────┬────────────────────────────────┘
                 │ optional — requires IndexStoreDB
                 ▼
┌─────────────────────────────────────────────────┐
│  Fallback: Name-Based Call Graph                │
│  (existing detectMutualCycles, demoted)         │
│                                                 │
│  Runs only when index is unavailable.           │
│  Emits .note explaining reduced accuracy.       │
└─────────────────────────────────────────────────┘
```

### What Changes

**Pass 1 (unchanged):** The `RecursionVisitor` continues to handle all single-file rules (1-7). These are syntactic patterns -- self-calls within a single function body, property getter self-references, convenience init forwarding loops -- that don't benefit from cross-file resolution. The visitor still collects `DeclarationInfo` records, but Pass 2 no longer consumes them when the index is available.

**Pass 2 (new):** `RecursionIndexPass` queries IndexStoreDB for all function/method symbols in the project's source files using `ConformanceQuery.symbolsInFiles(_:in:)`. For each symbol, it queries outgoing calls via `ConformanceQuery.findReferences(toUSR:in:roles: .call)`. This builds an adjacency list keyed by USR (not by display name), then runs Tarjan's SCC algorithm on the USR graph. Each SCC with two or more members and no base case is reported.

**Fallback (demoted):** When IndexStoreDB is unavailable (no index store found, stale index, configuration disabled), the existing `detectMutualCycles` method runs as before, but its diagnostics are tagged with `.note` severity explaining that results may include false positives from name-based resolution.

### New Files

| File | Purpose |
|------|---------|
| `Sources/RecursionAuditor/RecursionIndexPass.swift` | USR-based call graph construction, Tarjan SCC, cross-module cycle detection, protocol witness cycle detection |

### Modified Files

| File | Change |
|------|--------|
| `Sources/RecursionAuditor/RecursionAuditor.swift` | Add Pass 2 orchestration in `auditProject()`: detect project kind, open IndexStoreSession, run RecursionIndexPass, fall back to name-based if unavailable. Add `RecursionAuditorConfig` consumption. |
| `Sources/QualityGateCore/Configuration.swift` | Add `RecursionAuditorConfig` struct with `useIndexStore: Bool` field. Add `recursion` property to `Configuration`. |
| `Package.swift` | Add `"IndexStoreInfra"` to RecursionAuditor target dependencies. |

---

## 3. API Surface

### RecursionIndexPass

The new pass is an internal implementation detail of RecursionAuditor -- it has no public API beyond what the auditor's `check(configuration:)` already exposes. The pass is a static enum (no stored state, `Sendable` by construction):

```swift
/// USR-based cross-file recursion detection using IndexStoreDB.
///
/// Builds a call graph where nodes are USRs (Unified Symbol Resolution
/// identifiers) and edges are `.call` role references from the index store.
/// Runs Tarjan's SCC algorithm to find cycles of size >= 2, then filters
/// for cycles with no base case.
enum RecursionIndexPass {

    /// Inputs for a single pass execution.
    struct Inputs: Sendable {
        /// IndexStoreDB session, already opened and polled.
        let session: IndexStoreSession
        /// Absolute paths of source files to analyze.
        let sourceFiles: [String]
        /// Project root URL (for cross-module boundary detection).
        let projectRoot: URL
    }

    /// Results from the pass.
    struct Output: Sendable {
        /// Diagnostics for mutual cycles (USR-resolved).
        let mutualCycleDiagnostics: [Diagnostic]
        /// Diagnostics for cross-module cycles.
        let crossModuleCycleDiagnostics: [Diagnostic]
        /// Diagnostics for protocol witness cycles.
        let protocolWitnessCycleDiagnostics: [Diagnostic]
    }

    /// Run USR-based cycle detection.
    ///
    /// - Parameter inputs: Session, source files, and project root.
    /// - Returns: Diagnostics for all detected cycles.
    static func run(inputs: Inputs) -> Output
}
```

### RecursionAuditorConfig

```swift
/// Per-checker configuration for RecursionAuditor.
public struct RecursionAuditorConfig: Sendable, Equatable {
    /// Whether to use IndexStoreDB for USR-based call graph resolution.
    /// When true and the index is available, Pass 2 replaces name-based
    /// cycle detection with exact USR matching. When false or when the
    /// index is unavailable, falls back to name-based detection with
    /// reduced accuracy.
    public let useIndexStore: Bool

    /// Default configuration.
    public static let `default` = RecursionAuditorConfig(useIndexStore: true)

    public init(useIndexStore: Bool = true) {
        self.useIndexStore = useIndexStore
    }
}
```

### Configuration YAML

```yaml
recursion:
  useIndexStore: true   # default: true
```

### Orchestration in RecursionAuditor

The existing `auditProject(sources:configuration:)` method gains a conditional Pass 2 branch:

```swift
// After Pass 1 (per-file syntactic analysis) completes...

if configuration.recursion.useIndexStore {
    let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let project = ProjectKind.detect(at: projectRoot)

    if let session = try? StoreLocator.openSession(for: project) {
        let sourceFiles = sources.map(\.fileName)
        let output = RecursionIndexPass.run(inputs: .init(
            session: session,
            sourceFiles: sourceFiles,
            projectRoot: projectRoot
        ))
        allDiagnostics.append(contentsOf: output.mutualCycleDiagnostics)
        allDiagnostics.append(contentsOf: output.crossModuleCycleDiagnostics)
        allDiagnostics.append(contentsOf: output.protocolWitnessCycleDiagnostics)
    } else {
        // Fallback: name-based cycle detection with accuracy note
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "IndexStoreDB unavailable; mutual cycle detection uses name-based matching (may produce false positives from overloaded functions)",
            filePath: "",
            lineNumber: 0,
            columnNumber: 0,
            ruleId: "recursion.index-unavailable"
        ))
        allDiagnostics.append(contentsOf: detectMutualCycles(declarations: allDeclarations))
    }
} else {
    // Index disabled by configuration; use name-based detection
    allDiagnostics.append(contentsOf: detectMutualCycles(declarations: allDeclarations))
}
```

---

## 4. MCP Schema

Internal checker; no MCP schema required.

The RecursionAuditor is a `QualityChecker` consumed by the quality-gate CLI. It has no external API surface, no MCP tool definition, and no network-facing interface. The IndexStoreDB queries are local disk reads against the compiler's index store.

---

## 5. Safety & Concurrency

### Never Fails on Missing Index

The pass follows the established graceful degradation contract:
- If `StoreLocator` cannot find an index store path, the pass is skipped.
- If `IndexStoreSession` initialization throws (corrupt store, missing `libIndexStore.dylib`), the pass is skipped.
- If the index is stale (built against an older version of the source), USR queries may return incomplete results. Cycles detected are still valid (no false positives from stale data); the risk is false negatives (missed cycles whose edges are not yet indexed). This is acceptable -- a `.note` diagnostic records the index freshness status.
- Fallback always produces results, even if less precise.

### Sendable Compliance

- `RecursionIndexPass` is a caseless enum (no instances, no state). All methods are `static`. Sendable by construction.
- `RecursionIndexPass.Inputs` and `RecursionIndexPass.Output` are value types with all-`Sendable` fields.
- `IndexStoreSession` is `@unchecked Sendable` with an existing justification comment (single-task read-only access pattern). The pass does not share the session across tasks.
- `RecursionAuditorConfig` is a `Sendable` struct.
- The Tarjan SCC implementation is a pure function over arrays -- no shared mutable state.

### Pointer and Memory Safety

- No `withUnsafe*` calls. IndexStoreDB's Swift API returns owned values.
- The call graph adjacency list is `[[String]]` (USR strings), not pointer-indexed. No risk of dangling indices.
- Graph size is bounded by the number of function symbols in the project. For quality-gate-swift (~35K LOC), this is approximately 2,000 symbols. Memory usage for the adjacency list is negligible.

---

## 6. Compute & Backend

Not compute-intensive; no backend abstraction required.

The dominant cost is the IndexStoreDB queries, which are read-only lookups against an on-disk B-tree. Tarjan's SCC runs in O(V + E) time on the call graph. For a project with 2,000 function symbols and an average of 5 outgoing calls each, the graph has ~10,000 edges. Tarjan completes in under 1ms on this scale.

The index store open + poll step (in `IndexStoreSession.init`) is the most expensive operation (~200ms for a medium project). This cost is already paid by any checker that uses IndexStoreInfra; if multiple checkers share a session in the same quality-gate run, the cost is amortized.

No GPU, no network, no external service. Everything is local disk + CPU.

---

## 7. Dependencies

### Internal

| Dependency | Already Exists | Purpose |
|-----------|---------------|---------|
| `IndexStoreInfra` | Yes | `ProjectKind`, `StoreLocator`, `IndexStoreSession`, `ConformanceQuery`, `SourceWalker` |
| `QualityGateCore` | Yes (already a dependency) | `Diagnostic`, `Configuration`, `CheckResult` |
| `SwiftSyntax` / `SwiftParser` | Yes (already a dependency) | Pass 1 visitor (unchanged) |

### External

| Dependency | Already Exists | Purpose |
|-----------|---------------|---------|
| `IndexStoreDB` (apple/indexstore-db) | Yes (transitive via IndexStoreInfra) | USR-based symbol queries |

### New Dependency Edges

The only new edge is:

```
RecursionAuditor --depends-on--> IndexStoreInfra
```

`IndexStoreInfra` already depends on `IndexStoreDB`. No new external packages are introduced. The `Package.swift` change adds `"IndexStoreInfra"` to the RecursionAuditor target's dependency list.

---

## 8. Testing

### Test Strategy

Tests follow the existing pattern established by `UnreachableCodeAuditorTests` and `AppIntentsAuditorTests`: fixture-based tests that exercise the auditor end-to-end, plus targeted unit tests for the new pass.

### Test Cases

#### 8.1 Name Collision Scenarios (USR accuracy)

These tests verify that the USR-based graph does NOT produce false positives that the name-based graph would:

| Test | Setup | Expected Result |
|------|-------|-----------------|
| `testOverloadedFunctions_noFalsePositive` | Two methods with same name and labels but different parameter types; one calls the other | Zero `mutual-cycle` diagnostics |
| `testSameNamedMethodsOnUnrelatedTypes` | `Logger.write(message:)` and `FileWriter.write(message:)` where FileWriter calls Logger's method | Zero `mutual-cycle` diagnostics |
| `testGenuineMutualCycle_detectedByUSR` | `A.foo()` calls `B.bar()` which calls `A.foo()`, no base case | One `mutual-cycle` diagnostic per participant |
| `testMutualCycleWithBaseCase_noWarning` | Same as above but `A.foo()` has a guard-driven early exit | Zero diagnostics |

#### 8.2 Cross-Module Cycles (new rule 9)

| Test | Setup | Expected Result |
|------|-------|-----------------|
| `testCrossModuleCycle_detected` | Module A calls function in module B; module B calls back to module A; index contains both modules | `recursion.cross-module-cycle` warning on each participant |
| `testCrossModuleCycle_withBaseCase` | Same but one participant has a base case | Zero diagnostics |
| `testSingleModuleCycle_notTaggedAsCrossModule` | Mutual cycle within one module | `recursion.mutual-cycle` (not `cross-module-cycle`) |

#### 8.3 Protocol Witness Cycles (new rule 10)

| Test | Setup | Expected Result |
|------|-------|-----------------|
| `testProtocolWitnessCycle_detected` | Protocol extension default calls a requirement; conformer's witness calls the default | `recursion.protocol-witness-cycle` warning |
| `testProtocolExtensionDefault_noWitnessCycle` | Protocol extension default calls a requirement; conformer provides independent implementation | Zero diagnostics (no cycle) |

#### 8.4 Graceful Degradation

| Test | Setup | Expected Result |
|------|-------|-----------------|
| `testIndexUnavailable_fallsBackToNameBased` | Run auditor with `useIndexStore: true` but no index store on disk | `recursion.index-unavailable` note + name-based `mutual-cycle` results |
| `testIndexDisabledByConfig` | Run with `useIndexStore: false` | No note, name-based results only |
| `testIndexAvailable_noFallbackNote` | Run with valid index store | No `index-unavailable` note, USR-based results |

### Test Files

| File | Purpose |
|------|---------|
| `Tests/RecursionAuditorTests/RecursionIndexPassTests.swift` | Unit tests for the USR graph builder and cycle detection in isolation |
| `Tests/RecursionAuditorTests/RecursionAuditorIndexIntegrationTests.swift` | End-to-end tests for the full dual-pass pipeline with fixture projects |
| `Tests/RecursionAuditorTests/Fixtures/OverloadedMethods.swift` | Fixture: overloaded functions that should not trigger false positives |
| `Tests/RecursionAuditorTests/Fixtures/CrossModuleCycle/` | Multi-module fixture for cross-module cycle detection |

---

## 9. Open Questions

1. **Should name-based fallback emit lower-confidence diagnostics?** When the index is unavailable and the auditor falls back to name-based cycle detection, should the resulting `mutual-cycle` diagnostics be demoted from `.warning` to `.note`? The rationale for demotion: name-based matching is known to produce false positives, so the developer cannot trust the diagnostic at warning level. The rationale against: the name-based graph has been shipping at `.warning` since the auditor was written, and demoting it would hide genuine cycles in projects that never build an index store (e.g., CI environments without Xcode).

   **Resolved: Yes, name-based fallback results demoted to `note` severity.** The name-based graph is known to produce false positives from overloaded functions, and developers should not be expected to triage diagnostics that the tooling itself cannot verify. Fallback diagnostics will emit at `.note` severity with a message explaining reduced accuracy.

2. **Performance on large call graphs.** For projects with 10,000+ function symbols, the O(V + E) Tarjan pass itself is cheap, but the IndexStoreDB query phase (one `findReferences(toUSR:in:roles: .call)` per symbol) may produce measurable latency. Should the pass batch queries or set a symbol-count threshold above which it emits a `.note` and skips? Empirical measurement is needed -- the UnreachableCodeAuditor's IndexStorePass queries a similar number of symbols without reported performance issues, suggesting this may be a non-problem.

   **Resolved: Measure it, not a blocker.** Computers are only getting faster. We will include a benchmark test to track query-phase latency empirically. Note that IndexStoreDB's call graph is the same one Xcode uses for 150K+ LoC projects (like BusinessMath), and Tarjan SCC is O(V+E) linear in symbols and call edges. A 150K LoC project produces roughly 10K symbols, well within bounds -- under 10MB memory for the adjacency list. No threshold or skip logic needed; if a regression appears the benchmark test will catch it.

3. **Should the existing `detectMutualCycles` be removed entirely once Pass 2 is stable?** Keeping both code paths increases maintenance burden. However, removing the fallback means projects without an index store lose all cross-file cycle detection. The recommended approach is to keep the fallback but mark it `@available(*, deprecated, message: "Superseded by RecursionIndexPass")` after one release cycle of stability.

   **Resolved: Deprecate the name-based call graph code with `@available(*, deprecated)` but keep the code.** The `detectMutualCycles` method and its supporting call graph types will be annotated with `@available(*, deprecated, message: "Superseded by RecursionIndexPass -- use IndexStoreDB-based cycle detection")`. The code remains compiled and functional for fallback use, but is marked for future removal.

4. **Should Pass 2 re-check Pass 1 self-recursion rules with USR context?** Some Pass 1 rules (e.g., `unconditional-self-call`) use display name matching to determine if a call targets the enclosing function. With USR resolution, we could confirm or reject these findings. However, single-file self-calls are almost always correctly identified by name -- the USR disambiguation primarily benefits cross-function and cross-file calls. The added complexity is likely not justified.

   **Resolved: Yes, Pass 2 should re-validate Pass 1 findings.** If the tool is meant to be correct, users expect it to just work -- they should not need to mentally discount any subset of diagnostics. When the index is available, Pass 2 will use USR resolution to confirm or reject Pass 1's name-based self-recursion findings, suppressing any that USR resolution proves are false positives (e.g., an apparent self-call that actually targets an overload).

---

## 10. Documentation

A narrative article is required. The RecursionAuditor's `.docc` catalog already contains introductory material; this upgrade warrants a new article that combines call graph theory with IndexStoreDB concepts.

### Article: "How USR-Based Call Graph Resolution Works"

**Location:** `Sources/RecursionAuditor/RecursionAuditor.docc/USRBasedCallGraphResolution.md`

**Outline:**

1. **The problem with name-based call graphs.** Explain why `displayName` matching produces false positives: overloading, same-named methods on unrelated types, unresolvable receiver types. Show concrete Swift examples with identical display names that resolve to different symbols.

2. **What a USR is.** Unified Symbol Resolution identifiers are compiler-generated strings that uniquely identify every symbol across all modules. Format: `s:7ModuleA6ParserC5parse5inputAA0C6ResultVSS_tF` encodes module, type, function name, parameter types, and return type. Two overloads of `parse(input:)` with different parameter types have different USRs.

3. **How IndexStoreDB provides USRs.** The Swift compiler writes symbol records to an index store during compilation. IndexStoreDB reads these records and provides query APIs. `symbolsInFiles(_:in:)` returns all symbols defined in a set of files. `findReferences(toUSR:in:roles: .call)` returns all call sites targeting a specific symbol. Together, these build a precise call graph.

4. **Building the USR call graph.** Walk through the algorithm:
   - Enumerate all function/method symbols in the project's source files.
   - For each symbol, query its outgoing `.call` references.
   - Map each reference's target USR to the graph node.
   - The resulting adjacency list is keyed by USR, not by name.

5. **Tarjan's SCC on the USR graph.** The existing Tarjan implementation is reused with minimal changes (node type changes from `Int` index to `String` USR). Explain why SCC detection is the right algorithm: a cycle in the call graph means mutual recursion, and an SCC with no base case means the cycle is potentially infinite.

6. **Cross-module cycle detection.** Explain how IndexStoreDB's cross-module resolution enables detecting cycles that span module boundaries. Show the module-boundary heuristic: if two USRs in the same SCC have source locations in different module directories, the cycle is tagged as `cross-module-cycle`.

7. **Protocol witness cycle detection.** Explain the pattern: protocol extension provides a default that calls a requirement; a conformer's witness table routes the requirement back to the default. Show how IndexStoreDB's `.baseOf` and `.overrideOf` roles identify protocol witness relationships that create implicit call edges.

8. **Graceful degradation.** Explain the fallback to name-based detection and why the `.note` diagnostic is emitted. Describe the three scenarios: index available (full accuracy), index unavailable (name-based fallback), index disabled by configuration (name-based, no note).

### Rule Documentation Updates

Update the RecursionAuditor's rule catalog (in the `.docc` catalog and in `CLAUDE.md` quality gate patterns) with the two new rules:

| Rule ID | Severity | Description |
|---------|----------|-------------|
| `recursion.cross-module-cycle` | warning | Function participates in a mutual recursion cycle that crosses module boundaries |
| `recursion.protocol-witness-cycle` | warning | Protocol extension default creates a recursion cycle through a witness table |
| `recursion.index-unavailable` | note | IndexStoreDB unavailable; mutual cycle detection uses name-based matching |

---

## Implementation Order

| Phase | Work | Estimate | Dependencies |
|-------|------|----------|-------------|
| 1 | Add `RecursionAuditorConfig` to Configuration.swift; add `"IndexStoreInfra"` dependency to Package.swift | Small | None |
| 2 | Implement `RecursionIndexPass.swift` -- USR graph construction + Tarjan SCC + `mutual-cycle` upgrade | Medium | Phase 1 |
| 3 | Add `cross-module-cycle` detection to RecursionIndexPass | Small | Phase 2 |
| 4 | Add `protocol-witness-cycle` detection to RecursionIndexPass | Medium | Phase 2 |
| 5 | Wire Pass 2 into `RecursionAuditor.auditProject()` with fallback | Small | Phase 2 |
| 6 | Tests: overload false positive elimination, cross-module, protocol witness, degradation | Medium | Phase 5 |
| 7 | Documentation: `.docc` article, rule catalog updates | Small | Phase 6 |

Phases 2-4 are independent of each other once Phase 1 is complete. Phase 5 integrates all three. Total estimate: ~400 LOC new code, ~300 LOC tests, ~200 lines documentation.
