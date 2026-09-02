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
final class JustifiedCache: @unchecked Sendable {
    var entries: [String: Int] = [:]
}
```

The justification is a one-line line comment immediately above the declaration, or trailing on the same line. Block comments and gaps don't count.

### `concurrency.nonisolated-unsafe-no-justification`

Same shape, different keyword. `nonisolated(unsafe)` opts a stored property out of actor isolation. Rare but legitimate cases exist (process-wide debug counters, sentinel values). Document the reason or refactor.

```swift
// ❌ flagged
enum DebugCounters {
    nonisolated(unsafe) static var counter = 0
}

// ✅ accepted
enum JustifiedDebugCounters {
    // Justification: process-wide debug counter, race acceptable
    nonisolated(unsafe) static var counter = 0
}
```

Note that plain `nonisolated` (without `(unsafe)`) is fine and never fires this rule.

### `concurrency.sendable-class-mutable-state`

A class declaring `Sendable` (without `@unchecked`) commits to value-type-like immutability. A stored `var` violates that contract — and the compiler will not always catch it under inheritance or with private storage.

```swift
// ❌ flagged
final class Foo: Sendable {
    // Justification: illustrating the pattern this rule catches
    nonisolated(unsafe) private var x = 0  // private doesn't change the rules
}

// ✅ accepted
final class ImmutableFoo: Sendable {
    let x = 0
}
```

The `nonisolated(unsafe)` in the flagged example is what lets it compile at all under Swift 6 — and that is exactly the point. The escape hatch buys silence from the compiler, not safety, which is why a second pair of eyes (this rule) still looks at it.

If you genuinely need mutable state (with external synchronization), use `@unchecked Sendable` with a justification. That's what the escape hatch is for.

### `concurrency.sendable-class-non-sendable-property`

A `Sendable` class that stores a closure type without `@Sendable` is broken: the closure can capture non-Sendable state and you've lost your safety guarantees.

```swift
// ❌ flagged
final class HandlerBox: Sendable {
    // Justification: illustrating the pattern this rule catches
    nonisolated(unsafe) let handler: (Int) -> Void = { _ in }
}

// ✅ accepted
final class SendableHandlerBox: Sendable {
    let handler: @Sendable (Int) -> Void = { _ in }
}
```

### `concurrency.task-captures-self-no-isolation`

Inside an actor or `@MainActor` class, spawning a `Task { self.x += 1 }` looks innocent, but the
work is **deferred**: the enclosing call returns, and the mutation happens whenever the scheduler
gets to it. What it finds then may not be what the author was looking at.

This is an *ordering* hazard, not a data race. A non-detached `Task` inherits its actor's
isolation — it has since Swift 5.5 — so the access is serialised; the compiler will confirm that
by rejecting a redundant `await` on a synchronous isolated member with *"no 'async' operations
occur within 'await' expression"*. **So adding `await` is not the fix**, and this guide used to
say it was.

The fixes that work:

- **Do the isolated work before the `Task`.** If it must happen first, it must happen first —
  a comment saying "before sending" above a deferred task is a claim the scheduler is free to
  falsify.
- **Snapshot what the Task needs into locals**, named *apart* from the properties they came
  from. A local shadowing the property it snapshots reads, three lines later, as though it were
  still the live value.
- **Move a multi-step sequence into one isolated method the Task awaits.** Two statements in a
  deferred task can be interleaved between; one method cannot.

Real defects found by this rule, all of the last shape: a pending response registered inside a
nested task under a comment claiming it happened before the send; a reconnect that cancelled the
old connection and redialled as separate statements, so a concurrent reconnect could have the
cancel land on the connection that just replaced it.

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
actor BumpActor {
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
func redraw() { /* nonisolated drawing work */ }

// ❌ flagged
@MainActor
func f() {
    DispatchQueue.main.async { redraw() }
}

// ✅ accepted
@MainActor
func refresh() {
    Task { await MainActor.run { redraw() } }   // or just stay on the main actor
}
```

This rule fires for any DispatchQueue method (`.async`, `.sync`, `.asyncAfter`) when used inside isolated context.

### `concurrency.main-actor-deinit-touches-state`

In Swift 6, `deinit` is non-isolated even on `@MainActor` types. Touching instance stored properties from deinit will trap at runtime.

```swift
// ❌ flagged
@MainActor
class DeinitTrap {
    var x = 0
    deinit {
        print(x)   // runtime trap in Swift 6
    }
}

// ✅ accepted
@MainActor
class SafeDeinit {
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
// ❌ flagged (QualityGateCore is a target in this project's Package.swift)
@preconcurrency import QualityGateCore

// ✅ accepted (swift-log is a third-party dependency)
@preconcurrency import Logging
```

The CLI determines which modules are first-party by parsing `Package.swift` and collecting all `.target(name:)` literals. You can allowlist specific first-party modules during a transition via `allowPreconcurrencyImports:`.

### `concurrency.cancellation-checkpoint-after-loop`

A `for await` / `for try await` loop has a third exit path that is easy to miss: when the surrounding task is cancelled, the async sequence's iterator returns `nil` and the loop **ends quietly** — it does *not* throw `CancellationError`. So any code after the loop whose correctness depends on *why* the loop exited (marking a session "completed", flushing a "final" result, advancing a state machine) also runs on the cancelled path.

```swift
struct Sample: Sendable { let value: Double }

// Justification: all mutable state is guarded by `lock`
final class Session: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func markCompleted() {
        lock.lock()
        defer { lock.unlock() }
        completed = true
    }
}

let session = Session()
func process(_ sample: Sample) { _ = sample.value }

// ❌ flagged: cancellation is treated as semantic inside the loop, but the
//    post-loop code runs even when the loop exited because of cancellation.
func run(_ stream: AsyncThrowingStream<Sample, Error>) async throws {
    for try await sample in stream {
        try Task.checkCancellation()
        process(sample)
    }
    session.markCompleted()          // also reached on cancellation
}

// ✅ accepted: an explicit checkpoint separates "the stream finished" from
//    "we were cancelled" before the exit-reason-dependent statement.
func checkpointedRun(_ stream: AsyncThrowingStream<Sample, Error>) async throws {
    for try await sample in stream {
        try Task.checkCancellation()
        process(sample)
    }
    try Task.checkCancellation()
    session.markCompleted()
}
```

The rule is deliberately scoped: it fires only inside a function that already uses a cancellation checkpoint (`Task.checkCancellation()` or `Task.isCancelled`) — i.e. the author has demonstrably chosen to treat cancellation as semantic — and only when the first non-`defer` statement after the loop is reached without an intervening cancellation check. A `guard !Task.isCancelled else { … }`, an `if Task.isCancelled { … }`, or a `try Task.checkCancellation()` immediately after the loop all satisfy it. It is a `.warning` by default; set `ConcurrencyAuditorConfig.cancellationCheckpointStrict` to make it an `.error`.

## False positives and how to suppress them

The auditor is intentionally conservative on what it flags but pragmatic about suppression. Each rule has its own escape hatch:

- **unchecked-sendable, nonisolated-unsafe**: add a `// Justification:` comment.
- **sendable-class-mutable-state, sendable-class-non-sendable-property**: switch to `@unchecked Sendable` with a justification, or refactor.
- **task-captures-self-no-isolation**: use `await self.method()` to make the hop explicit.
- **dispatch-queue-in-actor**: use `await MainActor.run` or refactor to stay on-actor.
- **main-actor-deinit-touches-state**: move cleanup to an explicit isolated method called before deallocation.
- **preconcurrency-first-party-import**: add the module to `allowPreconcurrencyImports:` during a transition, then fix the underlying warnings and remove it.
- **cancellation-checkpoint-after-loop**: add `try Task.checkCancellation()` after the loop, or — if the post-loop code genuinely must run on both paths — put `// concurrency:exempt` on the loop line (recorded as a `DiagnosticOverride`, not silently dropped).

If you find yourself reaching for the escape hatch on every file, the rule is probably miscalibrated for your codebase. Open an issue.
