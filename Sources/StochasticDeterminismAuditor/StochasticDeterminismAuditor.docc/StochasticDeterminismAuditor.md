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

## What runs in `Tests/`

`Tests/` was skipped outright until it was not: every visitor method returned early on a test path, so a test could use `arc4random` freely. It is now walked, but for a subset of the rules.

| Rule | In `Sources/` | In `Tests/` |
|---|---|---|
| `stochastic-no-seed` | yes | no — `test-quality`'s `unseeded-random` |
| `stochastic-global-state` | yes | yes |
| `stochastic-collection-shuffle` | `.shuffled()` and `.shuffle()` | `.shuffle()` only |

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
```

## Topics

### Essentials

- ``StochasticDeterminismAuditor``
- <doc:StochasticDeterminismAuditorGuide>
