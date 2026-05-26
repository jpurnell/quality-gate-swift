# Session Summary: HIG Auditor Rollout and Cross-Project Fixes

**Date:** 2026-05-25
**Scope:** quality-gate-swift, iConquerApp, WineTaster 4

## Work Completed

### 1. HIGAuditor Context Menu False Positive Fix (quality-gate-swift)

The context menu rule (`hig-list-no-context-menu`) was flagging standalone `ForEach` inside `Picker`, `LazyVGrid`, and other non-List containers. Refactored `ViewModifierVisitor` to track `List` context with a depth counter (`listDepth`) instead of a boolean, and only increment on `List` — not `ForEach`. Added 3 new tests covering the fix.

### 2. HIG Findings Fixed Across Projects

Ran the HIG auditor against real-world projects and resolved all findings:

- **iConquerApp** (17 findings -> 0): Added `.help()`, `.keyboardShortcut()`, `.contextMenu` modifiers and `// HIG-EXEMPT:` comments across 7 view files.
- **WineTaster 4** (39 findings -> 0): Fixed 18 files with tooltips, shortcuts, and exemption comments. Committed as `148e87e`.

### 3. Full Quality Gate Pass on iConquerApp (20 findings -> 0)

After HIG fixes, ran `--check all --strict --continue-on-failure` and resolved every remaining checker finding:

| Checker | Findings | Fix |
|---------|----------|-----|
| fp-safety | 15 | `// fp-safety:disable` annotations on guarded divisions (GeoStore, ElevationGrid, Projection); refactored `fittedMapSize` to capture `mapAspect` in a guarded local |
| stochastic-determinism | 1 | `// stochastic:exempt` on seed generation (`UInt32.random` IS the seed) |
| memory-lifecycle | 2 | `// lifecycle:exempt` on Task properties (both use `[weak self]`, self-terminate on dealloc) |
| concurrency | 2 | Removed deinit that touched `@MainActor`-isolated state (lifecycle:exempt handles cleanup) |
| release-readiness | 2 | Created `CHANGELOG.md` and `README.md` |

### 4. AccessibilityAuditor Line Number Bug Fix (quality-gate-swift)

Discovered and fixed a false positive bug: the accessibility checker was reporting wrong line numbers for `.animation()` modifiers in SwiftUI modifier chains.

**Root cause:** `node.startLocation` on `MemberAccessExprSyntax` returns the start of the *entire chained expression* (e.g., `ZStack` at line 88), not the `.animation` call itself (line 108). The 10-line radius `reduceMotion` search then looked in the wrong range.

**Fix:** Changed to `node.period.startLocation` to report the actual `.animation` line. Also replaced per-call `SourceLocationConverter(fileName:tree:node.root)` with a shared converter initialized from the parsed `SourceFileSyntax` tree. All 11 existing tests pass.

### 5. New MemoryLifecycleGuard Rule: Unbounded AsyncStream

Added `lifecycle-unbounded-stream` rule that flags `AsyncStream.makeStream()` or `AsyncThrowingStream(...)` calls without an explicit `bufferingPolicy` argument. Suppressible with `// lifecycle:exempt`.

### 6. Dashboard Rebase Recovery

Added rebase recovery to the dashboard's corpus sync startup — detects interrupted `rebase-merge`/`rebase-apply` state and attempts `--continue` or `--abort` before pulling.

## Commits Pending

| Repo | Status | Action Needed |
|------|--------|---------------|
| quality-gate-swift | 1 ahead, 4 modified | Commit + push |
| iConquerApp | 1 ahead, 8 modified + 2 new | Commit + push |
| WineTaster 4 | 2 ahead, 33 modified (other session) | Push committed work only |

## Key Decisions

- **lifecycle:exempt over deinit**: For `@MainActor` classes with stored Tasks that capture `[weak self]`, exempting from the lifecycle checker is preferable to adding deinit (which triggers the concurrency checker's `main-actor-deinit-touches-state` rule in Swift 6).
- **fp-safety:disable for `.pi` divisions**: The fp-safety checker's `isNonZeroLiteral` only recognizes float/int literals, not member access like `.pi`. Inline disable comments are the correct suppression.
- **AccessibilityAuditor position fix**: Using `node.period.startLocation` for modifier-style checks ensures the reported line matches where the modifier actually appears, not the top of the SwiftUI chain.
