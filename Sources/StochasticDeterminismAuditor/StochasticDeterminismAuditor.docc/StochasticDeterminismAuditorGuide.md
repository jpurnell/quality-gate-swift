# Getting Started with StochasticDeterminismAuditor

@Metadata {
  @TechnologyRoot
}

## Overview

The Stochastic Determinism Auditor ensures production functions using randomness accept an explicit seed parameter, making results reproducible for debugging and auditing.

## What It Detects

### Unseeded Randomness (`stochastic-no-seed`)

This code will be flagged — the function uses randomness but provides no way to inject a seed:

```swift
// WARNING: stochastic-no-seed
func simulate(trials: Int) -> Double {
    var sum = 0.0
    for _ in 0..<trials {
        sum += Double.random(in: 0...1)
    }
    return sum / Double(trials)
}
```

The fix is to accept a generic `RandomNumberGenerator` parameter:

```swift
// PASSES: seed-injectable
func simulate(trials: Int, using rng: inout some RandomNumberGenerator) -> Double {
    var sum = 0.0
    for _ in 0..<trials {
        sum += Double.random(in: 0...1, using: &rng)
    }
    return sum / Double(trials)
}
```

### Global Random State (`stochastic-global-state`)

C-style random functions use hidden global state:

```swift
// WARNING: stochastic-global-state
func legacyRandom() -> Double {
    srand48(42)
    return drand48()
}
```

Replace with Swift's `RandomNumberGenerator` protocol.

### Collection Shuffle (`stochastic-collection-shuffle`)

```swift
// WARNING: stochastic-collection-shuffle
let deck = cards.shuffled()

// PASSES: seed-injectable
let deck = cards.shuffled(using: &rng)
```

## Exemptions

UUID generation and cryptographic randomness are never flagged:

```swift
func createSession() -> String {
    return UUID().uuidString  // Not flagged — identity, not data
}
```

Use `// stochastic:exempt` for intentionally non-reproducible code:

```swift
func addJitter() -> TimeInterval {
    return Double.random(in: 0...0.1) // stochastic:exempt
}
```

## Configuration

Disable specific rule categories:

```yaml
stochastic-determinism:
  flagCollectionShuffle: false  # skip shuffle checks
  flagGlobalState: false        # skip C-style checks
  exemptFunctions:
    - addUIJitter
  exemptFiles:
    - Sources/Networking/RetryPolicy.swift
```

## Integration

```bash
# Run standalone
quality-gate --check stochastic-determinism

# Include in full gate
quality-gate --check all --strict
```
