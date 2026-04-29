# ``StochasticDeterminismAuditor``

Enforces seed-injectable randomness in production code for reproducible results.

## Overview

The Stochastic Determinism Auditor flags production functions that use randomness without accepting an explicit `RandomNumberGenerator` parameter. In financial modeling and simulation code, non-reproducible results violate decision literacy — if a Monte Carlo run produces a surprising result, there must be a way to replay it.

This auditor walks `Sources/` only (test files are covered by ``TestQualityAuditor``). It detects Swift standard library randomness APIs, C-style global random state, and collection shuffle operations.

## Rules

| Rule ID | Flags | Severity |
|---|---|---|
| `stochastic-no-seed` | `.random()`, `.random(in:)`, or `SystemRandomNumberGenerator` in a function without an RNG parameter | warning |
| `stochastic-global-state` | `drand48()`, `srand48()`, `arc4random`, `arc4random_uniform` | warning |
| `stochastic-collection-shuffle` | `.shuffled()` or `.shuffle()` without `using:` parameter | warning |

## Exemptions

- Functions accepting `inout some RandomNumberGenerator` or generic RNG parameter
- `UUID()` and `UUID.init()` — identity generation, not data randomness
- `SecRandomCopyBytes` and CryptoKit — cryptographic randomness
- Files in `Tests/` directories
- Per-line `// stochastic:exempt` annotation
- Configured `exemptFunctions` and `exemptFiles`

## Configuration

```yaml
stochastic-determinism:
  exemptFunctions: []
  exemptFiles: []
  flagCollectionShuffle: true
  flagGlobalState: true
```

## Topics

### Essentials

- ``StochasticDeterminismAuditor``
- <doc:StochasticDeterminismAuditorGuide>
