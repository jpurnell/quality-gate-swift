# Design Proposal: Memory Lifecycle Guard

## 1. Problem

Swift's ARC handles most memory management automatically, but two categories of lifecycle bug slip through:

1. **Un-cancelled Task handles.** A class that stores a `Task<_, _>` property but has no `deinit` (or a `deinit` that doesn't cancel it) leaks work. The task continues running after the owning object is deallocated, potentially accessing stale state.

2. **Strong delegate/parent references.** A class storing a non-weak reference to a delegate or parent creates a retain cycle. Swift doesn't enforce `weak` on delegate properties — it's a convention, and convention-only rules get broken under time pressure.

The PointerEscapeAuditor covers unsafe pointer lifetimes, but these higher-level lifecycle patterns are unguarded.

## 2. Objective

Add a `MemoryLifecycleGuard` (`memory-lifecycle`) that flags classes with resource ownership patterns that suggest missing cleanup.

## 3. Proposed Rules

| Rule ID | Flags | Severity |
|---|---|---|
| `lifecycle-task-no-deinit` | Class has a stored property of type `Task<_, _>` but no `deinit` implementation | warning |
| `lifecycle-task-no-cancel` | Class has a stored property of type `Task<_, _>` and a `deinit` that doesn't call `.cancel()` on it | warning |
| `lifecycle-strong-delegate` | Class has a stored property whose name contains `delegate` or `parent` that is not declared `weak` | warning |
| `lifecycle-strong-closure` | Class has a stored closure property that captures `self` without `[weak self]` (best-effort detection) | info |

**Severity rationale:** All rules start as `warning` because each has legitimate exceptions. `lifecycle-strong-closure` is `info` because closure capture analysis from syntax alone is unreliable.

## 4. Implementation

**Approach:** SwiftSyntax AST visitor walking `Sources/` only.

**Detection strategy for `lifecycle-task-no-deinit`:**
1. Walk `ClassDeclSyntax` nodes
2. Check member block for stored properties with type annotation containing `Task<` or `Task?`
3. Check member block for presence of `DeinitializerDeclSyntax`
4. If Task property exists but no deinit, emit diagnostic

**Detection strategy for `lifecycle-strong-delegate`:**
1. Walk `ClassDeclSyntax` member blocks
2. Find stored properties (not computed) whose identifier contains `delegate`, `parent`, `owner`, or `dataSource` (configurable)
3. Check if the property binding has a `weak` or `unowned` modifier
4. If not, emit diagnostic

**Detection strategy for `lifecycle-strong-closure`:**
1. Walk stored property declarations with closure type annotations (e.g., `var onComplete: (() -> Void)?`)
2. This is `info`-level because we can't reliably detect `self` capture from the declaration site alone — the closure is assigned later

**Configuration:**
```yaml
memory-lifecycle:
  delegatePatterns: ["delegate", "parent", "owner", "dataSource"]
  requireTaskCancellation: true
  exemptFiles: []
```

**Exempt patterns:**
- `actor` types (actors manage their own isolation; Task cancellation semantics differ)
- Properties annotated with `// lifecycle:exempt`
- `unowned` delegate properties (intentional non-weak reference)

## 5. Implementation Plan

| # | Step | Effort | Dependencies |
|---|---|---|---|
| 1 | Define test cases: classes with/without deinit, Task properties, delegate patterns | Small | — |
| 2 | Implement `MemoryLifecycleGuard` with SyntaxVisitor | Medium | SwiftSyntax |
| 3 | Add Configuration extension | Small | QualityGateCore |
| 4 | Register in `allCheckers` | Trivial | Step 2 |
| 5 | DocC catalog (root + guide) | Small | Step 2 |
| 6 | Self-audit: verify quality-gate-swift itself passes | — | Steps 1-5 |

## 6. Success Criteria

- Flags `class Coordinator { var task: Task<Void, Never>? }` (no deinit)
- Passes `class Coordinator { var task: Task<Void, Never>?; deinit { task?.cancel() } }`
- Flags `class VC { var delegate: SomeDelegate }` (not weak)
- Passes `class VC { weak var delegate: SomeDelegate? }`
- Does not flag `actor` types with Task properties
- quality-gate-swift self-audit passes

## 7. Open Questions

1. **Should this flag `struct` types with Task properties?** Structs have value semantics — copying a struct copies the Task reference, but there's no deinit to cancel. Recommendation: flag with `info` severity in v2, skip in v1 to keep scope tight.
2. **Should `lifecycle-task-no-cancel` do flow analysis?** A deinit might cancel the task indirectly (via a helper method). Recommendation: v1 does string-level check for `.cancel()` in the deinit body. Accept false positives from indirect cancellation and add `// lifecycle:exempt` for those cases.
3. **Should this check for `NotificationCenter` observer removal?** Classic Objective-C retain bug. Recommendation: out of scope — modern `NotificationCenter` auto-removes on dealloc since iOS 9. Only relevant for manual `addObserver(_:selector:)` which is rare in modern Swift.

---

**Date:** 2026-04-29
**Author:** Justin Purnell + Claude Opus 4.6
