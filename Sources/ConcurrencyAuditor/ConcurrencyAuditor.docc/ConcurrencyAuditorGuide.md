# ConcurrencyAuditor Guide

A practical walkthrough of every ConcurrencyAuditor rule, with the bug it catches and the recommended fix.

## Why this auditor exists

Swift 6's strict concurrency model is correct but unforgiving. Code that compiles cleanly under Swift 6 can still ship runtime concurrency bugs in two specific shapes:

1. **Escape hatches used without justification.** `@unchecked Sendable` and `nonisolated(unsafe)` exist precisely because some valid code can't be expressed in the strict model. They're escape hatches, not skip-the-check buttons. Used silently, they hide concurrency bugs the compiler would otherwise catch.

2. **Patterns that compile but trap.** A `@MainActor` class deinit that touches isolated state. A `Task { self.x += 1 }` inside an actor. These compile under Swift 6 in many cases but trap or race at runtime.

ConcurrencyAuditor catches both shapes. It does not replace `swiftc -strict-concurrency=complete` — it complements it.

## Rule walkthrough

### `concurrency.unchecked-sendable-no-justification`

`@unchecked Sendable` tells the compiler: "trust me, this is thread-safe even though I can't prove it." If you can't write down *why* it's thread-safe, you should not be using `@unchecked Sendable`.

```swift
// ❌ flagged
final class Cache: @unchecked Sendable {
    var entries: [String: Int] = [:]
}

// ✅ accepted
// Justification: all access goes through cacheLock (NSLock); see Cache.swift:42
final class Cache: @unchecked Sendable {
    var entries: [String: Int] = [:]
}
```

The justification is a one-line line comment immediately above the declaration, or trailing on the same line. Block comments and gaps don't count.

### `concurrency.nonisolated-unsafe-no-justification`

Same shape, different keyword. `nonisolated(unsafe)` opts a stored property out of actor isolation. Rare but legitimate cases exist (process-wide debug counters, sentinel values). Document the reason or refactor.

```swift
// ❌ flagged
nonisolated(unsafe) static var counter = 0

// ✅ accepted
// Justification: process-wide debug counter, race acceptable
nonisolated(unsafe) static var counter = 0
```

Note that plain `nonisolated` (without `(unsafe)`) is fine and never fires this rule.

### `concurrency.sendable-class-mutable-state`

A class declaring `Sendable` (without `@unchecked`) commits to value-type-like immutability. A stored `var` violates that contract — and the compiler will not always catch it under inheritance or with private storage.

```swift
// ❌ flagged
final class Foo: Sendable {
    private var x = 0  // private doesn't change the rules
}

// ✅ accepted
final class Foo: Sendable {
    let x = 0
}
```

If you genuinely need mutable state (with external synchronization), use `@unchecked Sendable` with a justification. That's what the escape hatch is for.

### `concurrency.sendable-class-non-sendable-property`

A `Sendable` class that stores a closure type without `@Sendable` is broken: the closure can capture non-Sendable state and you've lost your safety guarantees.

```swift
// ❌ flagged
final class Foo: Sendable {
    let handler: (Int) -> Void = { _ in }
}

// ✅ accepted
final class Foo: Sendable {
    let handler: @Sendable (Int) -> Void = { _ in }
}
```

### `concurrency.task-captures-self-no-isolation`

Inside an actor or `@MainActor` class, spawning a `Task { self.x += 1 }` looks innocent but introduces a race: the Task body runs in a non-isolated context unless you explicitly hop back. The `await self.method()` form is the recommended fix because it makes the isolation hop visible.

```swift
// ❌ flagged
actor A {
    var x = 0
    func f() {
        Task {
            self.x += 1   // unsafe — runs off-actor
        }
    }
}

// ✅ accepted
actor A {
    var x = 0
    func bump() { x += 1 }
    func f() {
        Task {
            await self.bump()
        }
    }
}
```

Bare references to stored property names (without `self.`) are also flagged when they match the actor's stored properties.

`withTaskGroup`, `async let`, and `Task.detached` are intentionally NOT flagged by this rule. `Task.detached` will get its own rule in a future version.

### `concurrency.dispatch-queue-in-actor`

Mixing GCD with the structured concurrency model is almost always a smell. Inside actor or `@MainActor` context, prefer `await MainActor.run` or stay on-actor.

```swift
// ❌ flagged
@MainActor
func f() {
    DispatchQueue.main.async { … }
}

// ✅ accepted
@MainActor
func f() {
    Task { await MainActor.run { … } }   // or just stay on the main actor
}
```

This rule fires for any DispatchQueue method (`.async`, `.sync`, `.asyncAfter`) when used inside isolated context.

### `concurrency.main-actor-deinit-touches-state`

In Swift 6, `deinit` is non-isolated even on `@MainActor` types. Touching instance stored properties from deinit will trap at runtime.

```swift
// ❌ flagged
@MainActor
class A {
    var x = 0
    deinit {
        print(x)   // runtime trap in Swift 6
    }
}

// ✅ accepted
@MainActor
class A {
    var x = 0
    deinit {
        // empty — or only log static state
    }
}
```

Static references via `Self.x` are excluded from the check because static storage is not actor-isolated.

The recommended fix is to introduce an explicit isolated cleanup method that runs before deallocation.

### `concurrency.preconcurrency-first-party-import`

`@preconcurrency import SomeModule` tells the compiler to suppress strict-concurrency warnings from that module. This is a reasonable transition strategy for third-party dependencies you can't fix. It is **not** a reasonable strategy for your own code — fix the underlying warnings instead.

```swift
// ❌ flagged (MyAppCore is in this project's Package.swift)
@preconcurrency import MyAppCore

// ✅ accepted (Alamofire is third-party)
@preconcurrency import Alamofire
```

The CLI determines which modules are first-party by parsing `Package.swift` and collecting all `.target(name:)` literals. You can allowlist specific first-party modules during a transition via `allowPreconcurrencyImports:`.

## False positives and how to suppress them

The auditor is intentionally conservative on what it flags but pragmatic about suppression. Each rule has its own escape hatch:

- **unchecked-sendable, nonisolated-unsafe**: add a `// Justification:` comment.
- **sendable-class-mutable-state, sendable-class-non-sendable-property**: switch to `@unchecked Sendable` with a justification, or refactor.
- **task-captures-self-no-isolation**: use `await self.method()` to make the hop explicit.
- **dispatch-queue-in-actor**: use `await MainActor.run` or refactor to stay on-actor.
- **main-actor-deinit-touches-state**: move cleanup to an explicit isolated method called before deallocation.
- **preconcurrency-first-party-import**: add the module to `allowPreconcurrencyImports:` during a transition, then fix the underlying warnings and remove it.

If you find yourself reaching for the escape hatch on every file, the rule is probably miscalibrated for your codebase. Open an issue.
