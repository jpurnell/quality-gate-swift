# Observable Code Playbook: What Debuggable Code Actually Looks Like

**Date:** 2026-05-05
**Context:** Companion to `LoggingInstrumentationSystem.md` (approved). That proposal defines the architectural vision — instrumented types, auditor bypass detection, CLAUDE.md rules. This document grounds it in the actual debugging experience and defines the minimum intervention that makes Claude produce debuggable code by default.

**Read this after** reading LoggingInstrumentationSystem.md. This document challenges and refines it.

---

## The Problem, Concretely

A user has a SwiftUI app. The main screen takes 6 seconds to load. They ask Claude to diagnose it. Here's what happens:

**What Claude sees** (the code):
```swift
func loadMainScreen() async throws {
    let user = try await fetchUser()
    let preferences = try await fetchPreferences(for: user.id)
    let feed = try await fetchFeed(category: preferences.defaultCategory)
    let enriched = try await enrichFeedItems(feed, with: user.subscriptions)
    let sorted = rankItems(enriched, using: preferences.rankingWeights)
    await updateUI(with: sorted)
}
```

**What Claude does:** Guesses. "Maybe the network is slow?" Adds a print statement. Reruns. "Maybe it's the enrichment step?" Adds another print. Reruns. "Maybe it's the UI update on main thread?" Speculates for 20 minutes. Suggests Instruments. The user has now spent 45 minutes and still doesn't know which of 6 steps is slow.

**What Claude should see** (if the code were born observable):
```
[MainScreen] loadMainScreen started
[MainScreen] fetchUser completed in 0.340s
[MainScreen] fetchPreferences completed in 0.180s
[MainScreen] fetchFeed completed in 4.200s          ← here's your problem
[MainScreen] enrichFeedItems completed in 0.090s
[MainScreen] rankItems completed in 0.003s
[MainScreen] updateUI completed in 0.012s
[MainScreen] loadMainScreen completed in 4.825s
```

With this output, diagnosis takes 10 seconds: `fetchFeed` is the bottleneck. The investigation shifts immediately to "why is this specific API call slow?" — a tractable question instead of a haystack search.

---

## What Debuggable Code Looks Like (The Artifact)

This is the exact code Claude should produce when writing a multi-step async load sequence. Not aspirational — this is the minimum standard.

```swift
import os

struct MainScreenLoader {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.app",
        category: "MainScreen"
    )
    private let api: APIClient
    
    func load() async throws -> ScreenData {
        let sequenceStart = ContinuousClock.now
        logger.info("loadMainScreen started")
        
        // Step 1: User
        var stepStart = ContinuousClock.now
        let user = try await api.fetchUser()
        logger.info("fetchUser completed in \(stepStart.duration(to: .now), privacy: .public)")
        
        // Step 2: Preferences
        stepStart = ContinuousClock.now
        let preferences = try await api.fetchPreferences(for: user.id)
        logger.info("fetchPreferences completed in \(stepStart.duration(to: .now), privacy: .public)")
        
        // Step 3: Feed
        stepStart = ContinuousClock.now
        let feed = try await api.fetchFeed(category: preferences.defaultCategory)
        logger.info("fetchFeed completed in \(stepStart.duration(to: .now), privacy: .public) — \(feed.count, privacy: .public) items")
        
        // Step 4: Enrichment
        stepStart = ContinuousClock.now
        let enriched = try await enrichFeedItems(feed, with: user.subscriptions)
        logger.info("enrichFeedItems completed in \(stepStart.duration(to: .now), privacy: .public) — \(enriched.count, privacy: .public) items")
        
        // Step 5: Ranking (sync, but log it — could be expensive with large datasets)
        stepStart = ContinuousClock.now
        let sorted = rankItems(enriched, using: preferences.rankingWeights)
        logger.info("rankItems completed in \(stepStart.duration(to: .now), privacy: .public)")
        
        // Step 6: UI update
        stepStart = ContinuousClock.now
        await updateUI(with: sorted)
        logger.info("updateUI completed in \(stepStart.duration(to: .now), privacy: .public)")
        
        logger.info("loadMainScreen completed in \(sequenceStart.duration(to: .now), privacy: .public)")
        return ScreenData(items: sorted, user: user)
    }
}
```

**This is 12 extra lines of code.** Not new types. Not architecture. Twelve lines of `logger.info()` with `ContinuousClock` timing, using APIs that already ship with every Apple platform.

---

## Why the Structural Proposal Overshot

The approved proposal (LoggingInstrumentationSystem.md) defines 5 primitives: `InstrumentedClient`, `Pipeline`, `@Logged`, `withObservability`, `ResourceScope`. Here's what each actually buys you for the load-sequence problem above:

| Primitive | What it covers | What it misses |
|-----------|---------------|----------------|
| `InstrumentedClient` | Network request/response timing | Inter-step timing (doesn't know step 3 is `fetchFeed` vs step 1 is `fetchUser` — it sees individual HTTP requests, not the sequence) |
| `Pipeline` | Stage-by-stage item counts | Only works for array-in/array-out transforms; `fetchUser()` returns a single object, not a collection |
| `@Logged` | State enum transitions | Not relevant to load sequences |
| `withObservability` | Entry/exit timing for any operation | **This one actually works.** Wrapping each step gives you the output above |
| `ResourceScope` | Resource acquire/release | Not relevant to load sequences |

`withObservability` is the one primitive that directly solves the problem. The others solve adjacent problems (and may be worth building), but they don't address the core scenario.

Even `withObservability` has a tradeoff: it wraps each step in a closure, which changes the code shape:

```swift
// With withObservability — adds nesting, closure capture
let user = try await withObservability("fetchUser", logger: logger) {
    try await api.fetchUser()
}
let preferences = try await withObservability("fetchPreferences", logger: logger) {
    try await api.fetchPreferences(for: user.id)
}
```

vs. the inline approach:

```swift
// Inline logging — flat, no nesting, no closures
var stepStart = ContinuousClock.now
let user = try await api.fetchUser()
logger.info("fetchUser completed in \(stepStart.duration(to: .now), privacy: .public)")
```

The inline approach is more readable, easier for Claude to produce, and doesn't require any new types. The cost is that it's a pattern Claude has to follow, not a type that forces it.

---

## The Minimum Intervention

### What actually needs to happen

1. **Claude needs to know what debuggable code looks like.** Not abstract rules — a concrete before/after example like the one above. The CLAUDE.md instruction should include a literal code example, not just "add logging."

2. **Claude needs to know WHEN to add it.** The trigger is: "any function that contains 2+ `await` calls, or any function that's the entry point of a user-visible operation (view appearing, button tap, app launch)." This is a simple, memorable heuristic.

3. **The pattern must be low-friction.** If the pattern requires importing a new package, adopting a new type, or restructuring existing code, Claude won't do it consistently (and neither will humans). The pattern should use only `import os`, `Logger`, and `ContinuousClock` — things that already exist.

4. **The auditor catches the mechanical stuff.** Silent catch blocks, missing privacy annotations, bare `Logger()` init — these are genuinely AST-detectable and valuable. Don't try to detect "missing step-level logging" — that's the behavioral piece.

### Proposed CLAUDE.md instruction (revised)

```markdown
## Observability (Consumer-Facing Apps)

When writing or modifying async functions in application code:

**The 2-await rule:** If a function contains 2 or more `await` calls, or is
the entry point of a user-visible operation (view appearing, button tap, app
launch), instrument it with step-level timing:

    import os
    
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.app",
        category: "TypeName"
    )
    
    func loadData() async throws -> Result {
        let total = ContinuousClock.now
        logger.info("loadData started")
        
        var step = ContinuousClock.now
        let a = try await fetchA()
        logger.info("fetchA: \(step.duration(to: .now), privacy: .public)")
        
        step = ContinuousClock.now
        let b = try await fetchB(a.id)
        logger.info("fetchB: \(step.duration(to: .now), privacy: .public)")
        
        logger.info("loadData complete: \(total.duration(to: .now), privacy: .public)")
        return Result(a: a, b: b)
    }

This is 3 lines per step. The output lets anyone diagnose which step is slow
by reading Console.app — no Instruments, no breakpoints, no guessing.

**Every catch block** must log the error before recovering or rethrowing:

    } catch {
        logger.error("fetchB failed: \(error.localizedDescription, privacy: .public)")
        throw error
    }

**Privacy annotations** are mandatory on every interpolated value in Logger calls.
Use `.public` for counts, durations, status codes. Use `.private` for user IDs,
names, paths. Never log passwords, tokens, or credentials.
```

### Proposed coding rules section (revised)

The `13_LOGGING_INSTRUMENTATION.md` document should lead with the before/after example from this document, then codify:

1. **The 2-await rule** — when to instrument
2. **The step-timing pattern** — how to instrument (inline, with ContinuousClock)
3. **The catch-block rule** — every catch logs the error
4. **Privacy annotations** — mandatory on all interpolations
5. **Logger declaration** — one per type, subsystem = bundle ID, category = type name
6. **Log level guide** — the table from the structural proposal (unchanged)

The instrumented types (`InstrumentedClient`, `Pipeline`, etc.) move to an "Advanced Patterns" section as optional tools for teams that want deeper structural enforcement. They're good ideas — they're just not the minimum intervention.

### Proposed auditor rules (revised)

Keep from the structural proposal:
- `logging.missing-privacy` — AST-detectable, high value, near-zero false positives
- `logging.bare-logger-init` — AST-detectable, low-hanging fruit
- `logging.catch-without-logging` — AST-detectable (catch block with no logger call and not a rethrow)

Drop or defer:
- `logging.raw-urlsession` — only makes sense if InstrumentedClient exists and is adopted
- `logging.raw-file-io` — same; premature without the primitives package
- `logging.uninstrumented-async` — the v1 rule we already rejected; still unreliable

---

## The Debugging Experience We're Designing For

When a user says "this screen is slow," here's what should already be available:

### In Console.app or `log stream`

```bash
log stream --predicate 'subsystem == "com.myapp"' --level info
```

Output:
```
2026-05-05 10:23:01 [MainScreen] loadMainScreen started
2026-05-05 10:23:01 [MainScreen] fetchUser: 0.34s
2026-05-05 10:23:01 [MainScreen] fetchPreferences: 0.18s
2026-05-05 10:23:05 [MainScreen] fetchFeed: 4.20s
2026-05-05 10:23:05 [MainScreen] enrichFeedItems: 0.09s (47 items)
2026-05-05 10:23:05 [MainScreen] rankItems: 0.003s
2026-05-05 10:23:05 [MainScreen] updateUI: 0.012s
2026-05-05 10:23:05 [MainScreen] loadMainScreen complete: 4.83s
```

### What Claude does with this

Instead of guessing, Claude reads the log output and immediately says: "fetchFeed is taking 4.2 seconds. Let's investigate the feed API endpoint — check the request URL, look for pagination issues, check if the response payload is oversized, verify the server-side query isn't doing a full table scan."

That's a productive debugging session. It starts from observation, not speculation.

---

## What This Document Is For

Pass this to a Claude instance that has already read the structural proposal. It provides:

1. **Grounding** — what the actual debugging experience should look like
2. **Honest assessment** — where the structural proposal overshot and what the minimum intervention is
3. **Revised deliverables** — CLAUDE.md instruction, coding rules scope, auditor rules scope
4. **The 2-await rule** — a simple, memorable heuristic for when to instrument

The structural proposal's primitives (`InstrumentedClient`, `Pipeline`, etc.) remain approved as optional advanced patterns. This document narrows the mandatory minimum to something Claude can do with zero new dependencies: `Logger` + `ContinuousClock` + the 2-await rule.

---

## Open Questions for the Implementing Session

1. **Does the 2-await rule capture enough?** Single-await functions that are user-visible entry points (e.g., `onAppear { try await loadProfile() }`) should also be instrumented. Is "2+ awaits OR user-visible entry point" specific enough, or does it need a more concrete list of entry-point patterns?

2. **Should the coding rules document include the structural primitives at all?** Or should they live in a separate "Advanced Observability Patterns" proposal to keep the core document focused on the minimum?

3. **Error logging in `withObservability` vs. inline catch:** If a team does adopt `withObservability`, it handles error logging automatically. But the auditor's `catch-without-logging` rule would still fire on catch blocks inside the closure. Should `withObservability` usage suppress that rule?

4. **Retrofitting existing code:** The 2-await rule applies to new code Claude writes. For existing uninstrumented code, should we recommend a one-time audit pass? Or just let it happen organically as code is modified?
