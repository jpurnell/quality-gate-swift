# UnreachableCodeAuditor v8 — local dead stores (sibling checker)

**Status:** PLANNED · low priority (overlaps with Xcode warnings)
**Estimated cost:** 1-2 sessions
**Bug class:** different from v1-v7 — new domain

---

## What v8 catches

Pure-syntactic, in-function dead code at the **statement** level:

1. **Unread local bindings.** `let x = compute(); /* x never used */`
2. **Pointless writes.** `var y = 1; y = 2; print(y)` — the first
   assignment is dead.
3. **Unused parameters.** `func f(a: Int, b: Int) -> Int { a + a }` —
   `b` is never read.
4. **Shadowing without read.** `let x = 1; let x = 2; print(x)` — the
   outer `x` is dead.

These are the bug class that Xcode already catches with built-in
warnings (`-Wunused-variable` etc.) — so v8's value is **CI enforcement
in projects that don't fail builds on warnings.**

---

## Why this is a *sibling* checker, not v8 of "unreachable"

Everything in v1-v7 is *symbol-level* dead code (functions, properties,
types). v8 is *statement-level* dead code inside live functions. They
share zero infrastructure: no IndexStoreDB, no call graph, no project
detection. The only thing they share is `SwiftSyntax`.

Ship v8 as a new checker `local-dead-stores`, not as an iteration of
`unreachable`. Wire it into the same `quality-gate` CLI alongside
`unreachable`, `safety`, `doc-lint`, etc.

```
quality-gate --check local-dead-stores
```

The two checkers compose: a function flagged dead by `unreachable` is
trivially also full of dead stores; running both gives a layered view.

---

## Design

### New module
`Sources/LocalDeadStoreChecker/`
- `LocalDeadStoreChecker.swift` — `QualityChecker` conformance
- `BindingScopeAnalyzer.swift` — SwiftSyntax pass that builds a
  per-function scope tree, tracking each binding's read count

### Algorithm

For each function/init/closure body:

1. Walk statements in order.
2. For each `VariableDeclSyntax` / `FunctionParameterSyntax`,
   register a `Binding(name, declLine, kind)` in the current scope.
3. For each `DeclReferenceExprSyntax`, look up the binding (innermost
   scope first) and increment its read count.
4. For each `SequenceExprSyntax` / `InfixOperatorExprSyntax` whose
   operator is `=`, treat the LHS identifier as a *write*, the RHS as
   reads.
5. At scope exit, every binding with `readCount == 0` is dead. Emit a
   diagnostic with rule id `local.dead_store`.

### Edge cases

- `_ = expression` — explicit "discard" pattern, ignore.
- Bindings whose name starts with `_` — convention for "intentionally
  unused", ignore.
- `inout` parameters — count any write as a read (it's observable to
  the caller).
- `@discardableResult` doesn't apply (it's about return values, not
  bindings).
- Closures capturing outer bindings — references inside the closure
  count toward the outer binding's read count.

### Configuration

```yaml
local-dead-stores:
  ignoreUnderscorePrefix: true   # default
  ignoreSingleLineFunctions: false
```

---

## Test plan

Pure unit tests, no fixture package needed (the checker only needs
in-memory source strings via `auditSource`).

```swift
@Test("Flags unread let binding")
func unreadLet() async throws {
    let code = "func f() { let x = 1 }"
    let result = try await checker.auditSource(code, ...)
    #expect(result.diagnostics.contains { $0.ruleId == "local.dead_store" })
}
```

~15 tests covering each rule + each edge case.

---

## Why v8 might never happen

Honest assessment: Xcode catches most of these already. Users running
this checker would be:
- CI-only projects without an Xcode UI
- Projects that allow warnings (and so miss Xcode's findings)
- Multi-target packages where Xcode's warning hygiene is uneven

If your codebase doesn't fall into one of those buckets, v8 doesn't
buy you anything Xcode isn't already telling you. **Build it only if
you have a concrete project asking for it.**
