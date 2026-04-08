# Design Proposal: ConcurrencyAuditor

## 1. Objective

Catch Swift 6 concurrency bugs and dangerous escape hatches that compile cleanly but bite at runtime. Inspired by repeated Sendable/actor-isolation friction during Swift 6 migration work and a real Accelerate session that produced unsound concurrency code passing the strict-concurrency build.

**Master Plan Reference:** Phase 2 — Checker Modules (sibling to `RecursionAuditor`)

**Target patterns:**
- `@unchecked Sendable` declarations with no adjacent justification comment.
- `nonisolated(unsafe)` stored properties with no adjacent justification comment.
- `class` types declaring `Sendable` conformance while having `var` stored properties OR stored properties of non-Sendable types.
- `Task { ... }` blocks inside actor-isolated contexts that capture `self` without an explicit isolation hop.
- `DispatchQueue.main.async` calls inside `@MainActor` or actor-isolated methods (should be `await MainActor.run` or already on-actor).
- `@MainActor` types whose `deinit` references stored properties (`deinit` is non-isolated in Swift 6 — runtime trap).
- `@preconcurrency import` of first-party project modules (escape hatch should be reserved for third-party).

## 2. Proposed Architecture

**New module:** `Sources/ConcurrencyAuditor/`

**New files:**
- `Sources/ConcurrencyAuditor/ConcurrencyAuditor.swift` — Public `QualityChecker`
- `Sources/ConcurrencyAuditor/IsolationVisitor.swift` — `SyntaxVisitor` tracking actor isolation context as it walks
- `Sources/ConcurrencyAuditor/SendableInspector.swift` — Class/struct Sendable conformance analyzer
- `Sources/ConcurrencyAuditor/JustificationParser.swift` — Looks for `// Justification:` comments adjacent to flagged decls
- `Sources/ConcurrencyAuditor/ConcurrencyAuditor.docc/ConcurrencyAuditor.md`

**Tests:** `Tests/ConcurrencyAuditorTests/ConcurrencyAuditorTests.swift` with red/green fixtures.

**Modified files:**
- `Package.swift` — register module + test target, wire into `QualityGateCLI`
- `Sources/QualityGateCLI/QualityGateCLI.swift` — register checker
- `Sources/QualityGateCore/Configuration.swift` — add `concurrency: { enabled, severity, requireJustification }` block
- `Sources/QualityGateCore/QualityGateError.swift` — register `.concurrencyViolation`

## 3. API Surface

```swift
public struct ConcurrencyAuditor: QualityChecker {
    public static let identifier = "concurrency-auditor"
    public init(configuration: ConcurrencyAuditorConfiguration = .default)
    public func check(at projectRoot: URL) async throws -> CheckResult
}

public struct ConcurrencyAuditorConfiguration: Sendable {
    public var enabled: Bool
    public var severity: DiagnosticSeverity
    public var requireJustificationKeyword: String   // default: "Justification:"
    public var allowPreconcurrencyImports: Set<String>   // allowlist for third-party
    public static let `default`: Self
}
```

`Diagnostic.ruleID` values:
- `concurrency.unchecked-sendable-no-justification`
- `concurrency.nonisolated-unsafe-no-justification`
- `concurrency.sendable-class-mutable-state`
- `concurrency.sendable-class-non-sendable-property`
- `concurrency.task-captures-self-no-isolation`
- `concurrency.dispatch-queue-in-actor`
- `concurrency.main-actor-deinit-touches-state`
- `concurrency.preconcurrency-first-party-import`

## 4. MCP Schema

**N/A.** Same rationale as `RecursionAuditor` — surfaced via the umbrella `quality-gate` checker registry, not as a standalone MCP tool.

## 5. Constraints & Compliance

- **Concurrency:** `ConcurrencyAuditor` is itself `Sendable`. It must walk the talk — every type in this module is Sendable or actor-isolated.
- **Safety:** No force unwraps. No `try!`. Guard clauses for SyntaxNode lookups.
- **False-positive policy:** Require justification comments rather than guessing intent. If a developer adds `// Justification: shared global cache, mutation under cacheLock`, we accept and pass.
- **Configurability:** The justification keyword is configurable so projects with existing comment conventions can adapt.
- **No source modification:** Checker is read-only. No autofix in v1 (autofixes for concurrency are dangerous and almost always need human review).

## 6. Backend Abstraction

**N/A** — pure SwiftSyntax.

## 7. Dependencies

**Internal:**
- `QualityGateCore`
- `SwiftSyntax`, `SwiftParser`

**External:** None new.

**Note:** This auditor does NOT use the IndexStore (unlike `UnreachableCodeAuditor`). All checks are intra-file and AST-local. This keeps it fast and avoids requiring a successful build before running.

## 8. Test Strategy

**Test categories:**

| Rule | Red fixture | Green fixture |
|------|-------------|---------------|
| `unchecked-sendable-no-justification` | `final class Foo: @unchecked Sendable { var x = 0 }` | Same with `// Justification: synchronized via fooLock` directly above |
| `nonisolated-unsafe-no-justification` | `nonisolated(unsafe) static var counter = 0` | Same with `// Justification: process-wide debug counter, race acceptable` |
| `sendable-class-mutable-state` | `final class Foo: Sendable { var name: String = "" }` | `final class Foo: Sendable { let name: String = "" }` |
| `sendable-class-non-sendable-property` | `final class Foo: Sendable { let handler: (Int) -> Void }` | `final class Foo: Sendable { let handler: @Sendable (Int) -> Void }` |
| `task-captures-self-no-isolation` | `actor A { func f() { Task { self.x += 1 } } }` | `actor A { func f() { Task { await self.bump() } } }` |
| `dispatch-queue-in-actor` | `@MainActor func f() { DispatchQueue.main.async { ... } }` | Same body without the dispatch wrapper |
| `main-actor-deinit-touches-state` | `@MainActor class V { var x = 0; deinit { x = 0 } }` | `@MainActor class V { var x = 0; deinit { } }` |
| `preconcurrency-first-party-import` | `@preconcurrency import MyAppCore` (where MyAppCore is in the same Package.swift) | `@preconcurrency import ThirdPartyVendor` |

**Reference truth:** Hand-authored Swift fixtures + `.expected.json` files. The Swift 6 language reference and Apple's "Migrating to Swift 6" guide are the conceptual source of truth — every rule must cite a specific Swift Evolution proposal or Apple doc in its DocC entry.

**Validation trace example:**
- Input: `final class Cache: @unchecked Sendable { var entries: [String: Int] = [:] }` (no preceding comment)
- Expected: `concurrency.unchecked-sendable-no-justification` diagnostic at the `class` line, severity `.error`, message `"@unchecked Sendable requires a justification comment explaining why this is safe"`.

## 9. Open Questions

- **First-party vs third-party detection:** how does the auditor know which imports are first-party? **Proposed:** parse `Package.swift` once at the start of `check(at:)` and treat all `name:` strings from `targets:` as first-party. Cache the result.
- **Justification placement:** must the comment be on the line directly above, or anywhere within N lines? **Proposed:** the line directly above the decl, or trailing on the same line. Anything else is ambiguous.
- **Should we flag `@preconcurrency` on type declarations** (not just imports)? **Proposed:** yes, but as a warning tier and configurable.
- **What about `actor` types with `nonisolated` methods that mutate captured state?** **Proposed:** out of scope for v1 — too easy to get wrong without full type checking.

## 10. Documentation Strategy

**Documentation Type:** Narrative Article Required.

- 3+ APIs combined? Yes (Sendable, actor isolation, Task, DispatchQueue).
- 50+ line explanation? Yes — Swift 6 concurrency model is unfamiliar to many developers.
- Theory/background? Yes — actor isolation, Sendable, the runtime trap categories.

**Article name:** `ConcurrencyAuditorGuide.md` (in `ConcurrencyAuditor.docc/`). Must not collide with the type name `ConcurrencyAuditor`.

The article will:
- Explain each rule with a real-world example of the bug it catches
- Cite the relevant SE-XXXX evolution proposal per rule
- Document the justification-comment convention as a project standard
- Include a "false positives and how to suppress them" section

---

## Future Work (out of scope for v1)

- Cross-file isolation analysis (requires IndexStore integration like `UnreachableCodeAuditor`).
- `nonisolated` method capturing actor state.
- Detecting `Sendable` conformance on types whose generic parameters aren't Sendable-constrained.
- Flagging `Task.detached` without explicit reasoning.
