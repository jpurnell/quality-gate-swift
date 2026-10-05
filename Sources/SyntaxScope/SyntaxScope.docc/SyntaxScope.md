# ``SyntaxScope``

Which names are bound at a point in a SwiftSyntax tree, so a rule can tell a local from the member it shares a name with.

## Overview

A syntax-only rule that matches by name reports the wrong thing as soon as a local shadows a
member. `RecursionAuditor` met this first: a call to `walk(_:)` inside a function that declares
its own nested `walk` is not a self-call. `ConcurrencyAuditor` met it again: `let count = count`
before a `Task` is a snapshot, and the `count` read inside that `Task` is the snapshot, not the
actor-isolated property. Both now ask this module, which was extracted from `RecursionAuditor`
so that the answer is written once.

It depends on SwiftSyntax only. It does not import `QualityGateCore`, and it resolves nothing
semantically: typealiases, protocol witnesses and generic constraints stay with the index-backed
passes.

### Two ways to ask

- **While walking.** ``LexicalScope`` is a stack of frames. Push on entering a block, closure or
  case body, declare names as the walk meets them, and pop on leaving. Because declarations are
  recorded in traversal order, a local declared *after* a reference does not shadow it — which is
  how Swift reads, and the direction in which a mistake becomes a false negative rather than a
  false positive.
- **From a node.** ``visibleBindings(at:)`` climbs from a node to the top of the file and
  collects what is bound there: earlier statements of each enclosing list, the conditions of an
  enclosing `if` / `guard` / `while`, `for` patterns, `catch` and `switch` case bindings, closure
  parameters and capture lists, function parameters, and an accessor's `newValue` / `oldValue`.
  Only earlier statements count, and only of the enclosing list: a `let` in a sibling block is
  not visible.

### What binds a name

The `boundNames` overloads read one construct each — a pattern, a condition list, a closure, a
`catch` clause, a `switch` case, an accessor, a parameter list. Two distinctions are easy to get
wrong and are made here once:

- `case let .complete(completion)` parses as an expression pattern, so its binding is a
  reference node, not an identifier pattern; the case name is the callee and binds nothing.
- In `case .loaded(let device, expected)` only `device` binds. `expected` is a value the subject
  is compared with. ``bindingNames(inMatching:)`` keeps them apart.

A capture list binds too: `[log]` and `[log = self.log]` both fix `log` when the closure is
created. `[weak self]` rebinds the keyword, not a name, so ``boundName(of:)`` returns `nil` for
it.

### What it does not see

- **Bindings without a declaration in the file.** A name introduced by a macro expansion or a
  property wrapper's projection is not bound as far as this module can tell.
- **Types.** A name is bound or it is not; what it is bound *to* is not kept.
  `ExternalInputSyntax` keeps values for the security rules and answers a different question.
- **An unbalanced walk.** ``LexicalScope/pop()`` refuses to pop the root frame rather than trap,
  so a visitor that pops once too often degrades to "nothing is shadowed" — which reports — and
  does not crash the checker.

## Topics

### Tracking scope during a walk

- ``LexicalScope``

### Asking from a node

- ``visibleBindings(at:)``

### Reading one construct

- ``bindingNames(inMatching:)``
- ``boundName(of:)``
