# ``ConcurrencyAuditor``

Catches Swift 6 strict-concurrency bugs and dangerous escape hatches that compile cleanly but bite at runtime.

## Overview

ConcurrencyAuditor uses SwiftSyntax to walk a Swift source file and apply eight rules tailored to the Swift 6 concurrency migration. It maintains an explicit isolation context stack so nested types do not falsely inherit actor isolation, while functions inside isolated containers do.

This auditor is intentionally conservative on flagging and intentionally strict on suppression. The escape hatch for every rule that involves an "unsafe" Swift construct is a justification comment immediately above the declaration.

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `concurrency.unchecked-sendable-no-justification` | error | `@unchecked Sendable` without an adjacent justification comment |
| `concurrency.nonisolated-unsafe-no-justification` | error | `nonisolated(unsafe)` storage without an adjacent justification comment |
| `concurrency.sendable-class-mutable-state` | error | A class declaring `Sendable` (not `@unchecked`) with any stored `var` |
| `concurrency.sendable-class-non-sendable-property` | error | A `Sendable` class with a stored closure property that is not `@Sendable` |
| `concurrency.task-captures-self-no-isolation` | error | A `Task { … }` inside actor or `@MainActor` context that captures `self` without an explicit isolation hop |
| `concurrency.dispatch-queue-in-actor` | error | `DispatchQueue.main.async` (or any DispatchQueue method) used inside actor-isolated context |
| `concurrency.main-actor-deinit-touches-state` | error | A `@MainActor` class deinit that references an instance stored property |
| `concurrency.preconcurrency-first-party-import` | error | `@preconcurrency import` of a first-party module that should be fixed instead |

### Justification comments

Several rules accept a justification comment as the suppression mechanism. Adjacency is **strict**:

```swift
// Justification: synchronized via fooLock
final class Foo: @unchecked Sendable {}
```

or:

```swift
final class Foo: @unchecked Sendable {} // Justification: lock-protected
```

These both work. None of the following do:

```swift
// Justification: lock-protected
                                  // ← blank line breaks adjacency
final class Foo: @unchecked Sendable {}

final class Foo: @unchecked Sendable {}
// Justification: lock-protected   ← below the decl

/* Justification: lock-protected */ ← block comment, not line comment
final class Foo: @unchecked Sendable {}
```

The justification keyword is configurable via `ConcurrencyAuditor.init(justificationKeyword:)`. The default is `"Justification:"`.

### Isolation context tracking

The auditor maintains an explicit stack of `IsolationContext` values (`.none`, `.mainActor`, `.actor(name:)`). The top of the stack is the current isolation context. Pushes and pops happen at every type and function-level decl.

The rules that consult isolation are:

- `task-captures-self-no-isolation` — fires only when `currentIsolation.isIsolated`
- `dispatch-queue-in-actor` — same
- `main-actor-deinit-touches-state` — fires only when the enclosing type is `@MainActor`

Type decls (`class`, `struct`, `enum`) reset isolation to `.none` unless they have an explicit `@MainActor` attribute. So a class lexically nested inside an actor does not inherit actor isolation. Functions, initializers, and deinits inherit isolation from their parent unless they have their own `@MainActor` attribute.

### First-party imports

The `preconcurrency-first-party-import` rule needs to know which modules are first-party. The CLI parses the project's `Package.swift` once and passes the set of `.target(name:)` literals into the auditor's initializer. Single-file API users can pass their own set via `firstPartyModules:`. The rule is silently skipped when no first-party set is supplied.

You can allow specific modules to keep using `@preconcurrency` (perhaps because they're transitioning piecewise) via `allowPreconcurrencyImports:`.

### Out of scope

- Cross-file isolation analysis (would require IndexStore)
- Detecting `Sendable` conformance on types whose generic parameters aren't Sendable-constrained
- Flagging `Task.detached` without explicit reasoning (planned for v2)
- `actor` types with `nonisolated` methods that mutate captured state

## Topics

### Essentials

- ``ConcurrencyAuditor/check(configuration:)``
- ``ConcurrencyAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:ConcurrencyAuditorGuide>
