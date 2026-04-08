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
- `pointer-escape.return-from-with-block` *(error)* — covers direct return, return-via-wrapper (struct init, tuple, array/dict literal, optional, `Any`-box), ternary branches, and return from any nested block
- `pointer-escape.assigned-to-outer-capture` *(error)* — covers local outer var, global var, static property, and assignments inside `defer` blocks
- `pointer-escape.stored-in-property` *(error)* — instance property writes via `self.x = …` including computed-property setters
- `pointer-escape.appended-to-outer-collection` *(error)* — `outer.append(ptr)`, `outer.insert(ptr, at:)`, etc., where `outer` is captured from outside the with-block
- `pointer-escape.passed-as-inout` *(error)* — passing a tracked pointer as a function argument whose parameter is `inout`
- `pointer-escape.stored-closure-captures-pointer` *(error)* — assigning a closure literal that references a tracked pointer to an outer var or property (provable escape, no interprocedural reasoning needed)
- `pointer-escape.captured-by-escaping-closure` *(warning)* — the same closure-capture pattern when passed to a function whose parameter is `@escaping` and the closure is not assigned locally
- `pointer-escape.unmanaged-retain-leak` *(warning, opt-in)*
- `pointer-escape.opaque-roundtrip` *(warning)*

### Architectural refinements (incorporated from design audit)

1. **Closure parameter binding.** `PointerScopeVisitor` resolves the parameter name for each `withUnsafe*` closure: implicit `$0`, named (`{ ptr in … }`), and `_` (no tracking). Tuple destructuring is recognized but treated conservatively (track each component). The tracked identity is the bound name within that closure scope.

2. **Stack of pointer scopes.** Nested `withUnsafe*` calls push a new scope onto a stack. Each scope owns its bound name(s). Returning the *outer* pointer from within an *inner* closure is an escape — the visitor must search the entire active stack when resolving identifiers, not just the innermost scope.

3. **Escape via expression flow, not just direct mention.** `PointerExpressionTracker` walks any expression looking for tracked pointer identity. A pointer is "in" an expression if it appears anywhere in the syntax tree as:
   - The expression itself (`return ptr`)
   - An operand of `+` / `-` / `advanced(by:)` / subscript / `.baseAddress` / `.pointee`-of-pointer-not-value
   - An argument to an initializer or function call (`return Holder(ptr: ptr)`, `return [ptr]`, `return (ptr, 0)`)
   - A branch of a ternary (`condition ? ptr : other`)
   - The wrapped value of an `Any` cast (`let boxed: Any = ptr; return boxed`)
   - The right-hand side of a local `let`/`var` binding that is later returned (alias chase, intra-closure only)

4. **Branch-aware return detection.** Escape is checked at every `ReturnStmtSyntax` inside the closure body, not only the tail expression. Implicit-return single-expression closures (`{ ptr }`) are also checked.

5. **`defer` blocks.** Statements inside a `defer { … }` are walked exactly like the closure body — defer runs before the closure returns, but assignments persist.

6. **Aliases — intra-closure only.** A local `let alias = ptr` inside the same closure is tracked. Aliases passed into other functions are NOT chased (would require interprocedural analysis).

7. **Shadowing safety.** If a closure body declares a *new* variable that shadows the bound pointer name (`{ ptr in let ptr = 5; print(ptr) }`), the inner `ptr` is NOT a tracked pointer. The visitor maintains a per-scope symbol table.

8. **Closure literals stored outside = error (upgraded from warning).** Assigning `closure = { ptr.pointee }` to an outer var, or `self.handler = { ptr.pointee }` to a property, is structurally provable as an escape and reported at error tier. The warning tier (`captured-by-escaping-closure`) is reserved for closures *passed as arguments* to a function whose parameter is `@escaping` and which we cannot resolve.

9. **Robustness.** No crash on conditional compilation, macro-expanded code, or malformed input. Failure mode is "skip the construct, continue walking."

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

**Per-rule test layout.** One file per rule, plus shared scope/robustness suites:

```
Tests/PointerEscapeAuditorTests/
  TestHelpers.swift
  ReturnFromWithBlockTests.swift          // I + IV (return)
  AssignedToOuterCaptureTests.swift        // II.5, II.7
  StoredInPropertyTests.swift              // II.5 (self.x), II.5 (computed)
  AppendedToOuterCollectionTests.swift     // II.6
  PassedAsInoutTests.swift                 // II.8
  StoredClosureCapturesPointerTests.swift  // III.9 + III.10 (error tier)
  EscapingClosureWarningTests.swift        // IV (warning tier)
  UnmanagedTests.swift                     // VII
  OpaqueRoundtripTests.swift               // VIII
  NestedScopeTests.swift                   // V
  ShadowingTests.swift                     // VI.22
  AllowlistTests.swift                     // allowedEscapeFunctions config
  RobustnessTests.swift                    // IX (must-not-crash)
```

### I. Direct return escape (must error → `return-from-with-block`)

**Must flag:**
- Implicit-return single-expression closure: `withUnsafePointer(to: x) { $0 }`
- Explicit `return $0`
- Named param: `withUnsafePointer(to: x) { ptr in return ptr }`
- Multi-branch return — only one branch returns the pointer
- Return `.baseAddress`: `withUnsafeBufferPointer { $0.baseAddress! }`
- Return derived: `$0 + 1`, `$0.advanced(by: 1)`, `$0[2]`
- Alias-then-return: `let alias = $0; return alias`
- Wrapped in struct init: `return Holder(ptr: $0)`
- Wrapped in tuple: `return ($0, 0)`
- Wrapped in array literal: `return [$0]`
- Wrapped in dictionary literal: `return ["key": $0]`
- Wrapped in optional: function returns `UnsafePointer<Int>?` and body is `$0`
- Wrapped in `Any` box: `let boxed: Any = $0; return boxed`
- Ternary branch: `return condition ? $0 : other`
- Return inside nested `if`/`guard`/`switch`/`for` block, not just tail position
- Return from inner closure of nested `withUnsafe*` referencing the outer pointer

**Must not flag:**
- `return $0.pointee` (value, not pointer)
- `withUnsafeBufferPointer { $0.reduce(0, +) }`
- `_ = $0` (no return)
- Read-only computation that produces a non-pointer result

### II. Assignment escape (must error)

**Must flag — `assigned-to-outer-capture`:**
- `var leaked: UnsafePointer<Int>?; withUnsafePointer(to: x) { leaked = $0 }`
- Assignment to a global var: `globalPtr = $0`
- Assignment to a static property: `Cache.lastPtr = $0`
- Assignment inside a `defer` block: `defer { leaked = $0 }`

**Must flag — `stored-in-property`:**
- `self.cachedPtr = $0.baseAddress`
- Computed property setter: `self.computedPtr = $0` (where `computedPtr` has a setter)

**Must flag — `appended-to-outer-collection`:**
- `outerArray.append($0)`
- `outerArray.insert($0, at: 0)`
- `outerSet.insert($0)`

**Must flag — `passed-as-inout`:**
- Calling a function that takes `inout UnsafePointer<Int>?` and passing the tracked pointer (`assign(&leaked, $0)` style — flagged when `&leaked` and `$0` co-occur in the call)
- Conservative version: any call where `$0` appears alongside an `&` operand on an outer var

**Must not flag:**
- `leaked = $0.pointee` (value, not pointer)
- `self.cachedFirst = $0.first`
- Local-only assignment (`let alias = $0; print(alias.pointee)`)

### III. Closure-capture escape (error tier — `stored-closure-captures-pointer`)

**Must flag:**
- Closure literal stored to an outer var: `closure = { print($0.pointee) }` (where the inner `$0` actually refers to the tracked pointer via capture, not the closure's own param — common form: `closure = { print(ptr.pointee) }`)
- Closure literal stored to `self.handler`: `self.handler = { _ in ptr.pointee }`
- Returning a closure literal capturing the pointer: `return { ptr.pointee }`

**Must not flag:**
- Closure literal stored locally and called locally before returning: `let local = { ptr.pointee }; local()` (no escape)

### IV. Closure-capture escape (warning tier — `captured-by-escaping-closure`)

**Must flag at warning tier:**
- `DispatchQueue.global().async { _ = ptr.pointee }`
- `Task { _ = ptr.pointee }`
- Custom function whose parameter is `@escaping`: `register { ptr.pointee }`

**Must not flag:**
- Synchronous version: `DispatchQueue.global().sync { _ = ptr.pointee }`
- Pointer used inside a closure passed to a non-escaping parameter (e.g. `array.forEach { _ = ptr.pointee }`)

### V. Nested-scope correctness

**Must flag:**
- Inner closure returns the *outer* pointer:
  ```swift
  withUnsafePointer(to: x) { outer in
      withUnsafePointer(to: y) { inner in
          return outer
      }
  }
  ```
- Inner closure assigns the outer pointer to an outer-outer-scope variable

**Must not flag:**
- Inner closure uses only its own `inner` pointer and returns a derived value

### VI. Non-escapes (must NOT flag)

- Reading `$0.pointee`
- `$0.reduce(0, +)` on a buffer
- Mapping the buffer to value types: `$0.map { $0 * 2 }`
- Synchronous closure usage
- Pointer passed to a non-escaping function parameter
- Local alias used only within the closure
- **Shadowing:** `withUnsafePointer(to: x) { ptr in let ptr = 5; print(ptr) }` — the inner `ptr` is an `Int`, not the tracked pointer; must NOT flag

### VII. Unmanaged tests (warning tier, opt-in)

**Must flag:**
- `self.handle = Unmanaged.passRetained(obj).toOpaque()` with no matching `.release()` anywhere in the same type

**Must not flag:**
- Same with `deinit { Unmanaged<Foo>.fromOpaque(handle).release() }`
- `Unmanaged.passUnretained(obj).toOpaque()` (no retain to balance)

### VIII. Opaque round-trip

**Must flag:**
- Round-trip outside the closure: `let op = withUnsafePointer(to: x) { OpaquePointer($0) }; let typed = UnsafePointer<Int>(op)`

**Must not flag:**
- Round-trip kept entirely inside the same `with…` closure

### IX. Robustness / weird syntax (must-not-crash)

- Ternary return
- Guard return
- Switch return
- Trailing-closure syntax: `withUnsafePointer(to: x) { $0 }` vs `withUnsafePointer(to: x, { $0 })`
- Multi-line closure body
- Single-expression closure
- Conditional compilation (`#if DEBUG`)
- Macro-expanded code
- Malformed/invalid input

### Allowlist behavior

- `allowedEscapeFunctions = ["vDSP_fft_zip"]` — escape into that exact function name does NOT flag
- Escape into any other function still flags

### Suggested TDD implementation order (incorporated from audit)

1. Detect `withUnsafe*` closures
2. Track closure parameter binding (`$0`, named, `_`)
3. Detect direct return of tracked pointer
4. Add intra-closure alias tracking
5. Add assignment-to-outer detection
6. Add property/global/static detection
7. Add wrapped-return detection (struct init, tuple, collection literals, `Any` box)
8. Add `defer` and branch-return walking
9. Add stored-closure-literal detection (error tier)
10. Add nested-scope stack
11. Add escaping-API capture detection (warning tier)
12. Add `Unmanaged` and `OpaquePointer` rules

**Reference truth:** Hand-authored Swift fixtures + `.expected.json` files. The Swift documentation for `withUnsafePointer(to:_:)` and Apple's "Manual Memory Management" guide are the conceptual source of truth — each rule cites the specific paragraph in its DocC entry.

**Validation trace example:**
- Input: `func leak(_ x: Int) -> UnsafePointer<Int> { withUnsafePointer(to: x) { $0 } }`
- Expected diagnostic: `pointer-escape.return-from-with-block` at the closure body's return position, severity `.error`, message `"pointer escapes the with-block; the underlying memory is invalid after the closure returns"`.

## 9. Open Questions

- ~~`.baseAddress` tracking~~ **Resolved:** yes — same identity as the buffer pointer.
- ~~Pointer arithmetic~~ **Resolved:** `+`, `-`, `advanced(by:)`, subscript, `.baseAddress` all derive the same identity.
- ~~Local rebinding~~ **Resolved:** intra-closure aliases via per-scope symbol table; no interprocedural chasing.
- ~~`withMemoryRebound` scope~~ **Resolved:** yes, pushes a new tracked scope.
- **Default-argument capture** (`func store(p: UnsafePointer<Int> = ptr) { … }`): **Resolved:** out of scope, pathological. Document as known limitation.
- **Closure parameter `_`:** confirmed — no tracking, since the pointer is unnamed and unreachable.
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
