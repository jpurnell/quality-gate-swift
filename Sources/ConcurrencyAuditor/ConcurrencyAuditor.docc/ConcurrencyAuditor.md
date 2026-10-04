# ``ConcurrencyAuditor``

Catches Swift 6 strict-concurrency bugs and dangerous escape hatches that compile cleanly but bite at runtime.

## Overview

ConcurrencyAuditor uses SwiftSyntax to walk each Swift source file and apply nine rules tailored to the Swift 6 concurrency migration. It maintains an explicit isolation context stack so nested types do not falsely inherit actor isolation, while functions inside isolated containers do. Before any file is walked, a pre-pass reads every type declaration in the run, so an extension can take the isolation of the type it extends even when that type is declared in another file.

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
| `concurrency.main-actor-deinit-touches-state` | error | A nonisolated deinit of a `@MainActor` class that references an instance stored property. `isolated deinit` and `@MainActor deinit` are accepted |
| `concurrency.preconcurrency-first-party-import` | error | `@preconcurrency import` of a first-party module that should be fixed instead |
| `concurrency.cancellation-checkpoint-after-loop` | warning¹ | A `for await`/`for try await` loop, in a function that uses a cancellation checkpoint, followed by exit-reason-dependent code with no post-loop cancellation check |

¹ `.warning` by default; `.error` when `ConcurrencyAuditorConfig.cancellationCheckpointStrict` is set.

### Justification comments

Several rules accept a justification comment as the suppression mechanism. Adjacency is **strict**:

```swift
// Justification: synchronized via fooLock
final class Foo: @unchecked Sendable {}
```

or:

```swift
final class TrailingFoo: @unchecked Sendable {} // Justification: lock-protected
```

These both work. None of the following do:

```swift
// Justification: lock-protected

// (the blank line above breaks adjacency)
final class GapFoo: @unchecked Sendable {}

final class BelowFoo: @unchecked Sendable {}
// Justification: lock-protected   ← below the decl, so it does not count

/* Justification: lock-protected */ // ← block comment, not line comment
final class BlockCommentFoo: @unchecked Sendable {}
```

The justification keyword is configurable via `ConcurrencyAuditor.init(justificationKeyword:)`. The default is `"Justification:"`.

### Isolation context tracking

The auditor maintains an explicit stack of `IsolationContext` values (`.none`, `.mainActor`, `.actor(name:)`). The top of the stack is the current isolation context. Pushes and pops happen at every type and function-level decl.

The rules that consult isolation are:

- `task-captures-self-no-isolation` — fires only when `currentIsolation.isIsolated`
- `dispatch-queue-in-actor` — same
- `main-actor-deinit-touches-state` — fires only when the enclosing type is `@MainActor` and the deinit is not itself isolated (`isolated deinit`, or `@MainActor deinit`)

Type decls (`class`, `struct`, `enum`) reset isolation to `.none` unless they have an explicit `@MainActor` attribute. So a class lexically nested inside an actor does not inherit actor isolation.

An extension has the isolation of the type it extends. `@MainActor` or `nonisolated` on the extension itself decides first; otherwise the extended type is looked up by name — in the extension's own module, then in the modules its file imports — and an extension of a `@MainActor` type or of an actor is isolated like the type, with the type's stored properties in reach of implicit `self`. A module is the directory under `Sources/`, `Tests/` or `Plugins/`. When the type is declared somewhere the run does not read (the SDK, a dependency), when its module is not imported, or when two declarations under the name disagree, the extension is treated as non-isolated and nothing is reported in it. Functions, initializers, properties and subscripts inherit isolation from their parent unless the member says otherwise: `@MainActor` on the member makes it main-actor isolated, `nonisolated` makes it not isolated, and a `static` member of an actor is not isolated (a `static` member of a `@MainActor` type is). A deinit does not inherit: its body is nonisolated unless it is declared `isolated deinit` (the type's isolation) or `@MainActor deinit`.

### First-party imports

The `preconcurrency-first-party-import` rule needs to know which modules are first-party. The CLI parses the project's `Package.swift` once and passes the set of `.target(name:)` literals into the auditor's initializer. Single-file API users can pass their own set via `firstPartyModules:`. The rule is silently skipped when no first-party set is supplied.

You can allow specific modules to keep using `@preconcurrency` (perhaps because they're transitioning piecewise) via `allowPreconcurrencyImports:`.

### Out of scope

- Isolation a type acquires without an attribute: a subclass of a `@MainActor` class, conformance to a `@MainActor` protocol, a module built with default main-actor isolation, and custom global actors
- Extensions of types declared outside the package (SDK types, dependencies), and of typealiases
- Detecting `Sendable` conformance on types whose generic parameters aren't Sendable-constrained
- Flagging `Task.detached` without explicit reasoning (planned for v2)
- `actor` types with `nonisolated` methods that mutate captured state

## Topics

### Essentials

- ``ConcurrencyAuditor/check(configuration:)``
- ``ConcurrencyAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:ConcurrencyAuditorGuide>
