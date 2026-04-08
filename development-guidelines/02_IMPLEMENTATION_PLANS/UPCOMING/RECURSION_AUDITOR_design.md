# Design Proposal: RecursionAuditor

## 1. Objective

Catch infinite-recursion bugs in Swift source before they hit SourceKit/runtime. Inspired by a real incident where a convenience init forwarded to itself with identical arguments and only SourceKit caught it after the fact.

**Master Plan Reference:** Phase 2 — Checker Modules (new auditor in the same family as `SafetyAuditor` and `UnreachableCodeAuditor`)

**Target patterns:**
- Convenience initializers that forward to `self.init(...)` with the same argument labels and structurally identical values they received.
- Functions/methods where every return path calls `self`-recursively with structurally unchanged arguments and there is no guard-driven base case earlier in the body.
- Computed properties whose getter references the same property (`var foo: Int { foo }`).
- Subscripts whose getter references the same subscript with the same key.
- **Mutual recursion** within a single file OR across files in the same project: function A calls B, B calls A (or longer cycles A→B→C→A), and no participant has a guard-driven base case in any return path. Built via a project-wide call graph keyed by qualified name.
- **Setter self-recursion**: `set { value = newValue }` where `value` is the enclosing property — same trap as the getter version, just hits on write.
- **Subscript setter self-recursion**: `set { self[i] = newValue }` inside the same subscript.
- **Protocol extension default that calls itself**: `extension P { func f() { f() } }` — infinite recursion for any conformer that doesn't override.
- **Instance, static, nested, and generic methods** are all in scope. Throwing and async functions are in scope (recursion is shape-equivalent regardless of effects).
- **Cross-type mutual recursion** (`A.f` calls `B().g`, `B.g` calls `A().f`) — same call-graph machinery as mutual recursion, just with different qualified names.

## 2. Proposed Architecture

**New module:** `Sources/RecursionAuditor/`

**New files:**
- `Sources/RecursionAuditor/RecursionAuditor.swift` — Public `QualityChecker` entry point
- `Sources/RecursionAuditor/RecursionVisitor.swift` — `SyntaxVisitor` subclass walking decls
- `Sources/RecursionAuditor/CallSignature.swift` — Helper for "structurally identical args" comparison
- `Sources/RecursionAuditor/RecursionAuditor.docc/RecursionAuditor.md`

**New tests:** `Tests/RecursionAuditorTests/RecursionAuditorTests.swift` with red/green fixture pairs.

**Modified files:**
- `Package.swift` — register `RecursionAuditor` target + test target, add to `QualityGateCLI` deps
- `Sources/QualityGateCLI/QualityGateCLI.swift` — register checker
- `Sources/QualityGateCore/Configuration.swift` — add `recursion: { enabled, severity }` config block
- `Sources/QualityGateCore/QualityGateError.swift` — register `.recursionViolation`

## 3. API Surface

```swift
public struct RecursionAuditor: QualityChecker {
    public static let identifier = "recursion-auditor"
    public init(configuration: RecursionAuditorConfiguration = .default)
    public func check(at projectRoot: URL) async throws -> CheckResult

    /// Single-file audit (intra-file rules + best-effort intra-file cycle detection).
    public func auditSource(_ source: String, fileName: String, configuration: Configuration) async throws -> CheckResult

    /// Multi-file audit. Builds a project-wide call graph for cross-file
    /// mutual recursion detection. Pass every Swift source in the project.
    public func auditProject(sources: [(fileName: String, source: String)], configuration: Configuration) async throws -> CheckResult
}

public struct RecursionAuditorConfiguration: Sendable {
    public var enabled: Bool
    public var severity: DiagnosticSeverity   // .error by default
    public var includeWarnings: Bool          // gate the "all paths recurse" heuristic
    public static let `default`: Self
}
```

`Diagnostic.ruleID` values:
- `recursion.convenience-init-self`
- `recursion.computed-property-self`
- `recursion.subscript-self`
- `recursion.unconditional-self-call` *(warning tier)*
- `recursion.mutual-cycle` *(warning tier — covers intra-file, cross-file, intra-type, and cross-type cycles)*
- `recursion.setter-self` *(error)*
- `recursion.subscript-setter-self` *(error)*
- `recursion.protocol-extension-default-self` *(error)*

## 4. MCP Schema

**N/A.** This is a code-quality checker invoked via CLI/SPM plugin, not a tool surfaced to AI models. The umbrella `quality-gate` MCP description (if/when published) will list `recursion-auditor` as one of its checkers; no additional schema needed.

## 5. Constraints & Compliance

- **Concurrency:** `RecursionAuditor` is a value type and `Sendable`. All visitor state is local to a single `check` invocation.
- **Safety:** No force unwraps. Guard clauses for AST node lookups. No `try!` / `as!`.
- **Generics:** N/A.
- **No false positives over false negatives:** when in doubt, do NOT flag. The auditor is meant to catch the obvious; human review handles the rest.
- **Plugin parity:** Same `QualityChecker` protocol, same `Diagnostic` model, same reporters as existing auditors.

## 6. Backend Abstraction

**N/A** — pure SwiftSyntax AST walking. CPU-only by definition.

## 7. Dependencies

**Internal:**
- `QualityGateCore` (protocol, models)
- `SwiftSyntax`, `SwiftParser` (already used by `SafetyAuditor`)

**External:** None new.

## 8. Test Strategy

**Test categories:**
- **Convenience init self-recursion** — fixture: `init(name: String) { self.init(name: name) }` → must flag.
- **Convenience init forwarding to a different init** — `init(name: String) { self.init(name: name, age: 0) }` → must NOT flag.
- **Computed property self-reference** — `var foo: Int { foo }` → must flag. `var foo: Int { _foo }` → must NOT flag.
- **Subscript self-reference** — `subscript(i: Int) -> Int { self[i] }` → must flag.
- **Function with base case** — `func f(_ n: Int) -> Int { guard n > 0 else { return 0 }; return f(n - 1) }` → must NOT flag.
- **Function with no base case** — `func f(_ n: Int) -> Int { return f(n) }` → must flag at warning tier.
- **Mutual recursion (intra-file)** — `func a() { b() }` / `func b() { a() }` with no base case in either → must flag both at warning tier with a shared cycle ID. `func a(_ n: Int) { guard n > 0 else { return }; b(n - 1) }` / `func b(_ n: Int) { a(n - 1) }` → must NOT flag.
- **Cross-file mutual recursion** — `// A.swift: func a() { b() }` + `// B.swift: func b() { a() }` → must flag both via `auditProject(sources:)`. Same with a base case → must NOT flag.
- **Indirect recursion via closure** — out of scope for v1; document as deferred (e.g. `let g = { f() }; g()` will not flag).
- **Property observers (`didSet`/`willSet` mutation cycles)** — out of scope for v1; document as deferred. Will not flag `var x = 0 { didSet { x = 1 } }`.
- **Control-flow constant folding** (e.g. `if true { return f() }`) — out of scope; we do not constant-fold. Document as known limitation.
- **Indirect enums** (`indirect enum List { case node(Int, List) }`) — must NOT flag. Recursive value-type definitions are not call recursion.
- **Overload resolution sanity** — `func f(_ x: Int) { f(x: x) }` calls a *different* overload `f(x: Int)`; must NOT flag as self-recursion. Argument labels participate in identity.

**Reference truth:** Hand-authored Swift fixtures. Each fixture file pairs with a `.expected.json` listing the diagnostics that must (or must not) be produced. This keeps the oracle fully in-repo and avoids any LLM-generated expected values.

**Validation trace example:**
- Input: `convenience init(x: Int) { self.init(x: x) }`
- Expected diagnostic: `recursion.convenience-init-self` at the `init` line, severity `.error`, message `"convenience init forwards to itself with identical arguments"`.

## 9. Open Questions

- ~~Should mutual recursion (A → B → A) be in v1, or deferred to v2?~~ **Resolved:** intra-file mutual recursion is in v1 at warning tier; cross-file deferred.
- Should the auditor analyze `lazy var` initializers (which can self-reference)? **Proposed:** include — same pattern as computed property.
- For the warning tier ("all return paths recurse with unchanged args"), should we require argument-by-argument structural equality or only label equality? **Proposed:** structural equality; label-only is too noisy.

## 10. Documentation Strategy

**Documentation Type:** API Docs Only (DocC catalog with one short overview page).

- 3+ APIs combined? No.
- 50+ line explanation? No.
- Theory/background? No.

No narrative article required. The DocC overview will list each `ruleID`, show one positive and one negative fixture per rule, and link to the SafetyAuditor docs as a reference for the checker pattern.

---

## Future Work (out of scope for v1)

- Indirect recursion through closures or function references.
- Property observer mutation cycles (`didSet { self.x = ... }`).
- Control-flow constant folding (`if true`, `while true`).
- Cross-module recursion across SPM target boundaries (would require IndexStore).
- Performance/stress hardening for very large packages (>1k functions, deep cycles).
- Heuristic detection of "decreasing parameter" to reduce warning-tier false positives on valid recursion.
