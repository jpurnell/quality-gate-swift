# Design Proposal: PointerEscapeAuditor

## 1. Objective

Catch `Unsafe*Pointer` values escaping the scope that owns their underlying memory. Inspired by an Accelerate FFT backend bug where pointer-escape memory corruption blocked tests — the code compiled cleanly because Swift's safety net stops at the `with…` boundary.

**Master Plan Reference:** Phase 2 — Checker Modules (sibling to `RecursionAuditor`, `ConcurrencyAuditor`)

**Target patterns:**
- `withUnsafePointer(to:)` / `withUnsafeMutablePointer(to:)` / `withUnsafeBytes` / `withUnsafeMutableBytes` / `withUnsafeBufferPointer` / `withUnsafeMutableBufferPointer` / `withCString` / `withMemoryRebound` whose closure body causes the pointer parameter to escape via:
  - **Direct return** of the pointer (or `.baseAddress`, or pointer arithmetic on it).
  - **Assignment to a variable captured from outer scope** (`var leaked: UnsafePointer<Int>?` declared above the `with…` block, then `leaked = pointer`).
  - **Storage in a stored property** of `self` or any other reference reachable from outside the closure.
  - **Passing to an `@escaping` closure** that is itself stored or returned.
  - **Passing to a function whose parameter is an `@escaping` closure capturing the pointer**.
- `Unmanaged.passRetained(...).toOpaque()` flowing into stored state without a documented matching `.release()` (memory-leak adjacent, similar shape).
- `OpaquePointer` cast back to a typed pointer outside the scope where the typed pointer was originally borrowed.

## 2. Proposed Architecture

**New module:** `Sources/PointerEscapeAuditor/`

**New files:**
- `Sources/PointerEscapeAuditor/PointerEscapeAuditor.swift` — Public `QualityChecker`
- `Sources/PointerEscapeAuditor/PointerScopeVisitor.swift` — `SyntaxVisitor` tracking active `with…` closure scopes and their bound pointer parameter names
- `Sources/PointerEscapeAuditor/EscapeAnalyzer.swift` — Determines whether a given identifier reference is an escape (return / outer-capture assign / property store / escaping-closure capture)
- `Sources/PointerEscapeAuditor/PointerExpressionTracker.swift` — Resolves derived expressions (`.baseAddress`, `+ offset`, `[i]`) back to their root pointer identifier
- `Sources/PointerEscapeAuditor/PointerEscapeAuditor.docc/PointerEscapeAuditor.md`

**Tests:** `Tests/PointerEscapeAuditorTests/PointerEscapeAuditorTests.swift` with red/green fixtures.

**Modified files:**
- `Package.swift` — register module + test target
- `Sources/QualityGateCLI/QualityGateCLI.swift` — register checker
- `Sources/QualityGateCore/Configuration.swift` — add `pointerEscape: { enabled, severity }` block
- `Sources/QualityGateCore/QualityGateError.swift` — register `.pointerEscape`

## 3. API Surface

```swift
public struct PointerEscapeAuditor: QualityChecker {
    public static let identifier = "pointer-escape-auditor"
    public init(configuration: PointerEscapeAuditorConfiguration = .default)
    public func check(at projectRoot: URL) async throws -> CheckResult
}

public struct PointerEscapeAuditorConfiguration: Sendable {
    public var enabled: Bool
    public var severity: DiagnosticSeverity
    public var includeWarnings: Bool   // gate the indirect-escape heuristic
    public var allowedEscapeFunctions: Set<String>  // e.g. ["vDSP_fft_zip"] if user opts in
    public static let `default`: Self
}
```

`Diagnostic.ruleID` values:
- `pointer-escape.return-from-with-block` *(error)*
- `pointer-escape.assigned-to-outer-capture` *(error)*
- `pointer-escape.stored-in-property` *(error)*
- `pointer-escape.captured-by-escaping-closure` *(warning)*
- `pointer-escape.unmanaged-retain-leak` *(warning, opt-in)*
- `pointer-escape.opaque-roundtrip` *(warning)*

## 4. MCP Schema

**N/A.** Same rationale as the other auditors.

## 5. Constraints & Compliance

- **Concurrency:** `PointerEscapeAuditor` is `Sendable`.
- **Safety:** No force unwraps. Guard clauses for AST lookups.
- **Conservative bias:** error tier only when escape is provable from the AST. The `@escaping` closure capture path is warning tier because it requires interprocedural reasoning we deliberately do NOT do.
- **Allowlist for known-safe escape functions:** some Apple APIs (notably parts of vDSP and `CFData.getBytePtr`) intentionally accept pointers that outlive the `with…` block via documented contract. Users opt in via `allowedEscapeFunctions` rather than us shipping a global allowlist that drifts.
- **Read-only:** no autofix. Pointer fixes always need human review.

## 6. Backend Abstraction

**N/A** — pure SwiftSyntax.

## 7. Dependencies

**Internal:**
- `QualityGateCore`
- `SwiftSyntax`, `SwiftParser`

**External:** None new.

**Note:** Like `ConcurrencyAuditor`, this auditor is intra-file only. It does not require a successful build or IndexStore. It cannot follow pointer flow across function boundaries — that's a deliberate scope limit, not an oversight.

## 8. Test Strategy

**Test categories:**

| Rule | Red fixture | Green fixture |
|------|-------------|---------------|
| `return-from-with-block` | `func leak(_ x: Int) -> UnsafePointer<Int> { withUnsafePointer(to: x) { $0 } }` | `func use(_ x: Int) -> Int { withUnsafePointer(to: x) { $0.pointee } }` |
| `return baseAddress` | `withUnsafeBufferPointer { $0.baseAddress! }` | `withUnsafeBufferPointer { $0.reduce(0, +) }` |
| `assigned-to-outer-capture` | `var leaked: UnsafePointer<Int>?; withUnsafePointer(to: x) { leaked = $0 }` | Same with `leaked = $0.pointee` (value, not pointer) |
| `stored-in-property` | `withUnsafeBufferPointer { self.cachedPtr = $0.baseAddress }` | `withUnsafeBufferPointer { self.cachedFirst = $0.first }` |
| `captured-by-escaping-closure` (warning) | `withUnsafePointer(to: x) { ptr in DispatchQueue.global().async { _ = ptr.pointee } }` | Same body using `DispatchQueue.global().sync` |
| `unmanaged-retain-leak` (warning, opt-in) | `self.handle = Unmanaged.passRetained(obj).toOpaque()` with no `.release()` anywhere in the type | Same with a `deinit { Unmanaged<Foo>.fromOpaque(handle).release() }` |
| `opaque-roundtrip` (warning) | `let opaque = withUnsafePointer(to: x) { OpaquePointer($0) }; let typed = UnsafePointer<Int>(opaque)` | Round-trip kept inside the same `with…` closure |

**Reference truth:** Hand-authored Swift fixtures + `.expected.json` files. The Swift documentation for `withUnsafePointer(to:_:)` and Apple's "Manual Memory Management" guide are the conceptual source of truth — each rule cites the specific paragraph in its DocC entry.

**Validation trace example:**
- Input: `func leak(_ x: Int) -> UnsafePointer<Int> { withUnsafePointer(to: x) { $0 } }`
- Expected diagnostic: `pointer-escape.return-from-with-block` at the closure body's return position, severity `.error`, message `"pointer escapes the with-block; the underlying memory is invalid after the closure returns"`.

## 9. Open Questions

- **`.baseAddress` tracking:** should we treat `bufferPointer.baseAddress` as the same identity as `bufferPointer` for escape purposes? **Proposed:** yes — `baseAddress` IS the dangerous handle.
- **Pointer arithmetic:** `let p = $0 + 1` then `return p`. **Proposed:** track `+` / `-` / subscript on a tracked pointer as deriving the same identity.
- **Local rebinding:** `let alias = $0; return alias`. **Proposed:** track simple `let` / `var` aliases via the `PointerExpressionTracker` symbol table; do NOT chase aliases through function calls.
- **Should `withMemoryRebound` produce a new tracked scope?** **Proposed:** yes — its closure parameter is a freshly bound pointer that must not escape its block.
- **Cross-file flow:** explicitly out of scope. Document clearly in DocC.

## 10. Documentation Strategy

**Documentation Type:** Narrative Article Required.

- 3+ APIs combined? Yes (`withUnsafe*`, `Unmanaged`, `OpaquePointer`).
- 50+ line explanation? Yes — pointer escape semantics are subtle and most Swift developers don't write low-level code regularly.
- Theory/background? Yes — Swift's "borrowed for the duration of the closure" model is the whole reason this auditor exists.

**Article name:** `PointerEscapeAuditorGuide.md` (in `PointerEscapeAuditor.docc/`). Must not collide with the type name.

The article will:
- Explain the borrow-vs-escape model with diagrams
- Show the original Accelerate FFT incident as the canonical motivating example
- Document each rule with red/green fixtures
- Explain the `allowedEscapeFunctions` allowlist and when to use it
- Include a "limitations" section explicitly calling out that we don't follow pointers across function boundaries

---

## Future Work (out of scope for v1)

- Interprocedural escape analysis (would require IndexStore + call-graph reasoning).
- Detecting unbalanced `Unmanaged.passRetained` / `.release` pairs across the whole type, not just adjacent code.
- C-interop pointer flow (`UnsafePointer` passed into a C function whose declared lifetime is unclear).
- Detecting `withExtendedLifetime` misuse.
