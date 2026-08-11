# ``StochasticDeterminismAuditor``

Enforces seed-injectable randomness in production code for reproducible results.

## Overview

The Stochastic Determinism Auditor flags production functions that use randomness without accepting an explicit `RandomNumberGenerator` parameter. In financial modeling and simulation code, non-reproducible results violate decision literacy — if a Monte Carlo run produces a surprising result, there must be a way to replay it.

This auditor walks `Sources/` and `Tests/`. It detects Swift standard library randomness APIs, C-style global random state, and collection shuffle operations.

## Rules

| Rule ID | Flags | Severity |
|---|---|---|
| `stochastic-no-seed` | `.random()`, `.random(in:)`, or `SystemRandomNumberGenerator` in a function without an RNG parameter | warning |
| `stochastic-global-state` | `drand48()`, `srand48()`, `arc4random`, `arc4random_uniform` | warning |
| `stochastic-collection-shuffle` | `.shuffled()` or `.shuffle()` without `using:` parameter | warning |
| `stochastic-unseeded-test-call` | a test calls an API declaring a defaulted `seed:` and omits it | warning |

## `stochastic-unseeded-test-call`

The other three rules look for randomness *at the call site*. This one looks for an argument that was never written, which is a different problem and needs a different method.

A test constructs `MonteCarloSimulation(iterations: 100)`, leaves the defaulted `seed:` at `nil`, and asserts a statistical property of the draw. Nothing on that line is random — every random number is drawn inside the callee — so there is nothing for the other rules to match. The assertion holds for most draws and not all, and the test passes until the day it does not. A real case: a mean of 100 draws from Uniform(1000, 2000) required to land in [1400, 1600] is a 3.5-standard-error bound, which fails by chance about one run in 2,000. Rare enough to look stable, frequent enough to bite CI, and when it does the failure says nothing about the code.

### Two passes, no type information

1. **Over `Sources/`**, collect every function and initializer declaring a parameter labelled `seed` *with a default value*. An initializer is recorded under its enclosing type's name — that is what a call site writes — and a method or free function under its own base name. A required `seed:` is skipped: omitting it does not compile, so there is nothing to warn about. The default is the whole danger, because omission is silent and legal.
2. **Over `Tests/`**, flag any call to a harvested callable that has no `seed:` argument.

The project configures the rule itself; there is no list of API names to maintain.

Each signature also records the *other* argument labels, and a call matches only when every label it writes is one that signature accepts. Without that, one name is enough to collide: BusinessMath declares both `MonteCarloScenario.normal(mean:standardDeviation:numberOfScenarios:seed:)` and `ProbabilisticDriver.normal(name:mean:stdDev:)`, and matching on `normal` alone produced 42 findings against the second — over a quarter of the rule's output, all wrong. Label matching also silently retires calls to a `using: &generator` overload, which are seeded by construction.

A call with no arguments at all is never flagged: it resolves to some other overload that has no `seed:` to pass.

### Marking a test deliberately unseeded

Some tests are *about* the unseeded path — "nil seed is non-reproducible by contract" is a real one — and adding a seed would invert the assertion. Use `// Justification: …`, the spelling ``ConcurrencyAuditor`` uses for `@unchecked Sendable`, on the line above or inline:

```swift
// Justification: the unseeded path is the contract under test here; a seed would invert it
let a = (0..<20).map { _ in distributionChiSquared(degreesOfFreedom: 5) as Double }
```

The reason is required and is validated by `JustificationValidator` — the same bar the concurrency rules use. A bare `// Justification:` does not suppress; it changes the diagnostic to say the marker states no reason. The plain `// stochastic:exempt` marker does not suppress this rule at all, deliberately: a suppression that costs nothing to write is how a rule becomes noise.

## What runs in `Tests/`

`Tests/` was skipped outright until it was not: every visitor method returned early on a test path, so a test could use `arc4random` freely. It is now walked, but for a subset of the rules.

| Rule | In `Sources/` | In `Tests/` |
|---|---|---|
| `stochastic-no-seed` | yes | no — `test-quality`'s `unseeded-random` |
| `stochastic-global-state` | yes | yes |
| `stochastic-collection-shuffle` | `.shuffled()` and `.shuffle()` | `.shuffle()` only |
| `stochastic-unseeded-test-call` | no — harvest only | yes |

The split is deliberate. `TestQualityAuditor` already emits `unseeded-random` for `.random(…)`, `.shuffled(…)` and `SystemRandomNumberGenerator` inside `Tests/`, at warning severity. Emitting here too would put two warnings on one line, which trains people to read past both. What `unseeded-random` does *not* match is the C-style global functions and the in-place `.shuffle()` spelling — it tests the member name against the literal `"shuffled"` — so those are claimed here.

Advice is rewritten in a test file. "Add an `inout some RandomNumberGenerator` parameter" is something a `@Test` function cannot do: it has no caller to inject one. A test seeds its own generator, and the suggested fix says so.

Set `auditTests: false` to restore the old skip.

## Exemptions

- Functions accepting `inout some RandomNumberGenerator` or generic RNG parameter
- `UUID()` and `UUID.init()` — identity generation, not data randomness
- `SecRandomCopyBytes` and CryptoKit — cryptographic randomness
- Per-line `// stochastic:exempt` annotation
- Configured `exemptFunctions` and `exemptFiles`

## Configuration

```yaml
stochastic-determinism:
  exemptFunctions: []
  exemptFiles: []
  flagCollectionShuffle: true
  flagGlobalState: true
  auditTests: true
  flagUnseededTestCalls: true
```

## Topics

### Essentials

- ``StochasticDeterminismAuditor``
- <doc:StochasticDeterminismAuditorGuide>
