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

**Tests:** `Tests/ConcurrencyAuditorTests/` — **one test file per rule**, not one giant suite. This keeps assertions narrow and lets failures point at the responsible rule immediately.

```
Tests/ConcurrencyAuditorTests/
  UncheckedSendableTests.swift
  NonisolatedUnsafeTests.swift
  SendableClassMutableStateTests.swift
  SendableClassNonSendablePropertyTests.swift
  TaskCaptureTests.swift
  DispatchQueueInActorTests.swift
  MainActorDeinitTests.swift
  PreconcurrencyImportTests.swift
  IsolationStackTests.swift           // shared infra correctness
  Fixtures/
    FakePackage.swift                 // for preconcurrency-import tests
```

**Architectural refinements (incorporated from design audit):**

1. **Isolation context stack.** `IsolationVisitor` maintains an explicit stack:
   ```swift
   enum IsolationContext { case none, mainActor, actor(name: String) }
   ```
   Push on entering `actor`, `@MainActor` decl (class/struct/extension/func), or isolated extension; pop on exit. Required to handle nested types correctly. Several rules (`task-captures-self-no-isolation`, `dispatch-queue-in-actor`) consult the top of the stack to decide whether to fire.

2. **`Task` detection must be structural, not substring.** Match `FunctionCallExprSyntax` whose `calledExpression` is `IdentifierExprSyntax("Task")`. Do NOT fire on `withTaskGroup`, `async let`, or `Task.detached` (the latter is a future rule). The check is on the identifier syntax node, not on the source text.

3. **Sendable-class mutability rule is purely structural.** Any stored `var` (including `private var`, `private(set) var`) in a class declaring `Sendable` (without `@unchecked`) fires. We do NOT attempt to detect locks or mutexes — that's exactly what the justification comment escape hatch on `@unchecked Sendable` is for. Subclasses of NSObject and similar are out of scope; let the developer use `@unchecked Sendable + Justification`.

4. **`@MainActor deinit` heuristic.** Inside a `@MainActor` class's `deinit`, collect every `IdentifierExprSyntax` whose text matches a stored property name in the same type. No semantic resolution. Static-property references (`Self.x`) are excluded. This is intentionally conservative — it produces some false positives, suppressible via justification.

5. **Package.swift parsing for first-party detection.** At the start of `check(at:)`, parse `Package.swift` once and cache the set of first-party target names by extracting `.target(name: "...")` literal strings. `auditSource` (single-file API) skips this rule entirely since it has no project context. Match imports as: `ImportDeclSyntax` whose `attributes` contain `@preconcurrency` AND whose `path.first?.name.text` is in the first-party set AND not in `allowPreconcurrencyImports`.

6. **Justification comment placement is strict.** Either:
   - On the line **immediately above** the declaration (no blank line between), OR
   - **Trailing on the same line** as the declaration.
   Anything else (two lines above, below the decl, in a block comment) does NOT count. Tested explicitly.

7. **Robustness:** The auditor must not crash on malformed code, conditional compilation (`#if`), or macro-expanded syntax it doesn't understand. Failure mode is "skip the construct, continue walking."

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

**Per-rule test matrix.** Each rule gets its own test file. Within each file, every red fixture is paired with at least one green fixture to keep precision honest.

### `unchecked-sendable-no-justification`

**Must flag:**
- `final class Foo: @unchecked Sendable {}` — no justification at all
- `struct Foo: @unchecked Sendable {}` — value-type variant
- `extension Foo: @unchecked Sendable {}` — retroactive conformance
- `final class Foo: @unchecked Sendable {} // no justification` (the trailing comment doesn't contain the keyword)
- Same as above with mutable state present (still violation — justification is what matters, not the body)
- Justification placed two lines above (must NOT count — adjacency required)
- Justification placed *below* the decl (must NOT count)
- Justification inside a `/* … */` block comment two lines up (decide policy: **does NOT count**)

**Must not flag:**
- `// Justification: synchronized via NSLock` directly above
- Trailing on same line: `final class Foo: @unchecked Sendable {} // Justification: lock-protected`
- Custom keyword config (`requireJustificationKeyword: "SAFETY:"`) with `// SAFETY: protected by actor`

### `nonisolated-unsafe-no-justification`

**Must flag:**
- `nonisolated(unsafe) static var counter = 0` (top-level)
- `actor A { nonisolated(unsafe) var x = 0 }` (inside actor)

**Must not flag:**
- `nonisolated var x: Int { 0 }` (the safe `nonisolated`, no `(unsafe)`)
- Justified variant with `// Justification: …` directly above

### `sendable-class-mutable-state`

**Must flag (one diagnostic per offending property):**
- `final class Foo: Sendable { var x = 0 }`
- `final class Foo: Sendable { private var x = 0 }`
- `final class Foo: Sendable { private(set) var x = 0 }`
- `final class Foo: Sendable { var x: Int }` (uninitialized stored var)
- Two-var class → expect **2 diagnostics**, one per property

**Must not flag:**
- `final class Foo: Sendable { let x = 0 }` (immutable)
- `final class Foo { var x = 0 }` (no Sendable conformance)
- `struct Foo: Sendable { var x = 0 }` (struct value semantics — out of scope)
- `final class Foo: @unchecked Sendable { var x = 0 }` (handled by the unchecked rule, not this one)

### `sendable-class-non-sendable-property`

**Must flag:**
- `final class Foo: Sendable { let handler: (Int) -> Void }` (closure not marked `@Sendable`)
- Generic closure without `@Sendable`: `let handler: (T) -> Void`

**Must not flag:**
- `let handler: @Sendable (Int) -> Void`
- `let name: String` (Sendable stdlib type)
- Class is not Sendable at all

### `task-captures-self-no-isolation`

**Must flag:**
- Inside actor, `Task { x += 1 }` (implicit self)
- Inside actor, `Task { self.x += 1 }` (explicit self)
- Nested: `Task { Task { self.x += 1 } }`
- Inside `@MainActor class`, same patterns

**Must not flag:**
- `Task { await self.bump() }` (explicit isolation hop)
- `Task { await self.x }` (read-only via await)
- Non-actor context: `class A { func f() { Task { print("hi") } } }`
- `withTaskGroup { … }` and `async let` (these are NOT `Task` constructions)
- `Task.detached { … }` — out of scope for v1, defer to future rule

### `dispatch-queue-in-actor`

**Must flag:**
- `@MainActor func f() { DispatchQueue.main.async { } }`
- `actor A { func f() { DispatchQueue.main.async { } } }`
- `actor A { func f() { DispatchQueue.global().async { } } }` (any DispatchQueue inside actor isolation, not just main)

**Must not flag:**
- Top-level `func f() { DispatchQueue.main.async { } }` (no isolation context)
- Same usage in a non-isolated class

### `main-actor-deinit-touches-state`

**Must flag:**
- `@MainActor class A { var x = 0; deinit { print(x) } }` (read)
- `@MainActor class A { var x = 0; deinit { x = 0 } }` (write)
- Property reference inside a nested expression: `deinit { logger.log(x) }`

**Must not flag:**
- `deinit {}` (empty)
- `deinit { print("cleanup") }` (no property reference)
- `deinit { print(Self.staticValue) }` (static property — different storage)
- Class is not `@MainActor`-isolated

### `preconcurrency-first-party-import`

**Test harness:** A `Fixtures/FakePackage.swift` with `targets: [.target(name: "MyAppCore"), .target(name: "MyAppUI")]` is loaded by the test setup so the auditor sees a known first-party set.

**Must flag:**
- `@preconcurrency import MyAppCore`
- `@preconcurrency import MyAppUI`

**Must not flag:**
- `@preconcurrency import Alamofire` (third-party — not in target list)
- `@preconcurrency import MyAppCore` when `allowPreconcurrencyImports = ["MyAppCore"]`
- Plain `import MyAppCore` without `@preconcurrency`

### Isolation stack correctness (cross-rule)

A dedicated `IsolationStackTests.swift` exercises the visitor's stack model independent of any single rule:

- Nested types: `actor A { class Inner { func f() { … } } }` — `Inner.f` must NOT inherit `A`'s actor isolation.
- `@MainActor extension Foo { func f() { … } }` — `f` is MainActor-isolated.
- Multiple nested `@MainActor` declarations push/pop correctly without leaking state.

### Edge-case robustness matrix (must-not-crash)

Each test confirms the auditor produces diagnostics OR zero diagnostics — but never crashes — on:

| Case | Expectation |
|------|-------------|
| Nested types | Isolation stack stays correct |
| `@MainActor extension Foo` | Isolation propagates to extension members |
| Multiline declarations spanning many lines | Comment-adjacency still detected |
| Inline trailing comment `} // Justification: …` | Counts as justification when on the decl line |
| Generic constraints `class Foo<T>: Sendable where T: Sendable` | No false positive |
| Conditional compilation `#if DEBUG …` branches | No crash; both branches walked |
| Macro-expanded code | No crash if a macro is present |
| Malformed/syntactically invalid code | No crash; auditor returns whatever diagnostics it could produce |

**Reference truth:** Hand-authored Swift fixtures + `.expected.json` per fixture. The Swift 6 language reference and Apple's "Migrating to Swift 6" guide are the conceptual source of truth — every rule must cite a specific Swift Evolution proposal or Apple doc in its DocC entry.

**Validation trace example:**
- Input: `final class Cache: @unchecked Sendable { var entries: [String: Int] = [:] }` (no preceding comment)
- Expected: `concurrency.unchecked-sendable-no-justification` diagnostic at the `class` line, severity `.error`, message `"@unchecked Sendable requires a justification comment explaining why this is safe"`.

**Reference truth:** Hand-authored Swift fixtures + `.expected.json` files. The Swift 6 language reference and Apple's "Migrating to Swift 6" guide are the conceptual source of truth — every rule must cite a specific Swift Evolution proposal or Apple doc in its DocC entry.

**Validation trace example:**
- Input: `final class Cache: @unchecked Sendable { var entries: [String: Int] = [:] }` (no preceding comment)
- Expected: `concurrency.unchecked-sendable-no-justification` diagnostic at the `class` line, severity `.error`, message `"@unchecked Sendable requires a justification comment explaining why this is safe"`.

## 9. Open Questions

- ~~First-party vs third-party detection~~ **Resolved:** parse `Package.swift` once at the start of `check(at:)` and treat all `.target(name:)` literals as first-party. `auditSource` (single-file API) skips this rule entirely. Cached per checker invocation.
- ~~Justification placement~~ **Resolved:** strict adjacency — line directly above the decl, OR trailing on the same line. Two-lines-above, below, and block-comment forms do NOT count and are tested explicitly.
- **Block-comment justifications (`/* Justification: … */`):** **Proposed:** do NOT count for v1. Line comments only. Reasoning: line comments are unambiguously associated with one declaration; block comments float and create false-positive suppressions.
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
