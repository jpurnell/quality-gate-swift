# IndexStoreInfra Upgrade Map

**Date:** 2026-06-03
**Status:** Mapping Complete -- Individual Proposals Attached

---

## Overview

IndexStoreInfra provides shared cross-file analysis infrastructure: project detection (`ProjectKind`), index store location and freshness (`StoreLocator`), IndexStoreDB session management (`IndexStoreSession`), protocol conformance and symbol reference queries (`ConformanceQuery`), and source file enumeration (`SourceWalker`).

Currently two checkers use it: **UnreachableCodeAuditor** (mandatory dual-pass) and **AppIntentsAuditor** (optional Pass 2). This document maps every checker against IndexStoreInfra capabilities and identifies which ones gain meaningful new analysis power.

---

## Established Integration Pattern

All IndexStoreInfra upgrades follow the **optional Pass 2** pattern established by UnreachableCodeAuditor:

1. **Pass 1 (Syntactic)** -- always runs, per-file SwiftSyntax analysis, produces diagnostics
2. **Pass 2 (Cross-module)** -- optional, requires IndexStoreDB, produces additional diagnostics
3. **Graceful degradation** -- if index unavailable or stale, emit `.note` and continue
4. **Configuration toggle** -- `useIndexStore: Bool` in the checker's config section

Pass 2 never promotes Pass 1 results and never fails the gate when the index is unavailable.

---

## Upgrade Candidates

### Tier 1 -- Transformative (major new capabilities)

| Checker | Current Scope | IndexStoreInfra Unlock | Proposal |
|---------|--------------|----------------------|----------|
| **ConcurrencyAuditor** | Single-file | Cross-file Sendable validation, actor isolation boundary detection, `@preconcurrency` necessity verification | `CONCURRENCY_AUDITOR_INDEX_UPGRADE.md` |
| **RecursionAuditor** | Multi-file (name-based) | USR-based call graph replaces heuristic name matching; eliminates overload false positives | `RECURSION_AUDITOR_INDEX_UPGRADE.md` |

### Tier 2 -- Significant (reduces false positives/negatives)

| Checker | Current Scope | IndexStoreInfra Unlock | Proposal |
|---------|--------------|----------------------|----------|
| **MemoryLifecycleGuard** | Single-file | Cross-file Task cancellation verification, delegate lifecycle tracking | `MEMORY_LIFECYCLE_INDEX_UPGRADE.md` |
| **DocCoverageChecker** | Single-file | Inherited doc detection (protocol defaults), usage-weighted coverage | `DOC_COVERAGE_INDEX_UPGRADE.md` |
| **ComplexityAnalyzer** | Intra-module call graph | Cross-module call graph amplification via IndexStoreDB | `COMPLEXITY_ANALYZER_INDEX_UPGRADE.md` |

### Tier 3 -- Incremental (deferred)

| Checker | Potential Benefit | Why Deferred |
|---------|------------------|--------------|
| **LoggingAuditor** | Verify `os.Logger` availability across module | Low false-positive rate already; benefit marginal |
| **StochasticDeterminismAuditor** | Track seeded RNG propagation across calls | Rare pattern; name-based heuristic sufficient |
| **FloatingPointSafetyAuditor** | Cross-file type resolution to reduce FP false positives | High engineering cost for modest precision gain |
| **MCPReadinessAuditor** | Already has optional Pass 2 hook | No further work needed |

### Not Applicable

| Checker | Reason |
|---------|--------|
| SafetyAuditor | Per-expression patterns; cross-file adds nothing |
| TestQualityAuditor | Per-test-function scope |
| PointerEscapeAuditor | Per-closure-scope; pointer lifetimes are lexical |
| ProcessSafetyAuditor | Per-function pipe ordering |
| AccessibilityAuditor | Per-view accessibility labels |
| HIGAuditor | Per-view HIG compliance |
| ContextAuditor | Per-expression consent/analytics patterns |
| BuildChecker | Subprocess-based, no AST |
| TestRunner | Subprocess-based, no AST |
| DocLinter | Subprocess-based, no AST |
| DependencyAuditor | JSON/YAML parsing only |
| ReleaseReadinessAuditor | String/regex matching only |
| StatusAuditor | Markdown parsing only |
| SwiftVersionChecker | Package.swift version line only |
| MemoryBuilder | YAML/Markdown only |
| ConsistencyChecker | IJS corpus only |
| DiskCleaner | File system operations only |
| XcodeBuildChecker | Subprocess-based |

---

## Implementation Order

```
Phase 1: ConcurrencyAuditor Pass 2     (highest impact, Swift 6 pain point)
Phase 2: RecursionAuditor USR upgrade   (accuracy improvement, existing call graph)
Phase 3: ComplexityAnalyzer USR adopt   (adopts RecursionAuditor's USR call graph)
Phase 4: MemoryLifecycleGuard Pass 2    (lifecycle safety across files)
Phase 5: DocCoverageChecker Pass 2      (false positive reduction)
```

Phases 1-2 are independent and could run in parallel. Phase 3 depends on Phase 2 (shares USR call graph infrastructure). Phases 4-5 are independent of each other.

**Resolved dependency chain:** RecursionAuditor ships USR-based call graph first, then ComplexityAnalyzer adopts it (not deferred). ConcurrencyAuditor is independent and can run in parallel with Phase 2.

**Additional proposals needed (from MemoryLifecycleGuard review):**
- Combine/AnyCancellable lifecycle tracking -- write proposal, build if purely additive or if infrastructure needs early integration
- Retain cycle detection via IndexStoreDB -- write proposal, likely a separate checker or extension

---

## Shared Infrastructure Additions

Several proposals share needs that should be added to IndexStoreInfra once, not per-checker:

| Capability | Used By | ConformanceQuery Addition |
|-----------|---------|--------------------------|
| Type hierarchy queries (superclass/protocol chain) | ConcurrencyAuditor, MemoryLifecycleGuard | `findSuperTypes(of:in:)` |
| Stored property enumeration by USR | ConcurrencyAuditor, MemoryLifecycleGuard | `storedProperties(of:in:)` |
| Method existence check by type USR | MemoryLifecycleGuard | `hasMethod(named:in:ofType:)` |
| Reference count by USR | DocCoverageChecker | `referenceCount(of:in:)` |
| Caller/callee resolution by USR | RecursionAuditor, ComplexityAnalyzer | `callees(of:in:)`, `callers(of:in:)` |

These would be added to `ConformanceQuery` as the proposals are implemented, not all at once.

---

## Success Criteria

Each upgraded checker must:
1. Pass 1 produces identical results to today (no regressions)
2. Pass 2 adds new diagnostics that Pass 1 cannot detect
3. Missing index produces `.note` only, never fails the gate
4. Configuration toggle defaults to `true` (use index when available)
5. New tests cover Pass 2 logic with mock/real IndexStoreDB
6. Quality gate passes 0/0 after upgrade
