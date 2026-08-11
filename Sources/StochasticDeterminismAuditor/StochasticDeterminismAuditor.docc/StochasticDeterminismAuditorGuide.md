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
func seededSimulate(trials: Int, using rng: inout some RandomNumberGenerator) -> Double {
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
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

let cards = Array(1...52)
var rng = SeededGenerator(seed: 42)

// WARNING: stochastic-collection-shuffle
let deck = cards.shuffled()

// PASSES: seed-injectable
let seededDeck = cards.shuffled(using: &rng)
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

## Test files

`Tests/` is walked, but not for every rule. `TestQualityAuditor` already emits
`unseeded-random` there for `.random(…)`, `.shuffled(…)` and
`SystemRandomNumberGenerator`, so this auditor stays quiet on those and claims what
that rule misses: C-style global state, and the in-place `.shuffle()` spelling.

```swift
import Testing

@Test func rolls() {
    let n = arc4random_uniform(6)  // WARNING: stochastic-global-state
    var deck = cards
    deck.shuffle()                  // WARNING: stochastic-collection-shuffle
    let x = Double.random(in: 0...1) // handled by test-quality's unseeded-random
    #expect(n < 6)
    #expect(deck.count == 52)
    #expect(x >= 0)
}
```

Advice differs in a test file. A `@Test` function has no caller to inject a generator,
so the suggested fix asks it to seed one itself rather than to take a parameter.

### Omitted seeds (`stochastic-unseeded-test-call`)

A seed that is available and not passed is invisible to every rule above — the call site
has no randomness on it at all:

```swift
import Testing

struct MonteCarloSimulation {
    struct Outcome {
        let mean: Double
    }

    let iterations: Int
    let enableGPU: Bool
    var generator: SeededGenerator

    // The `seed` parameter with a default value is what marks this API seedable.
    init(iterations: Int, enableGPU: Bool = false, seed: UInt64 = 0) {
        self.iterations = iterations
        self.enableGPU = enableGPU
        self.generator = SeededGenerator(seed: seed)
    }

    mutating func run() throws -> Outcome {
        var total = 0.0
        for _ in 0..<iterations {
            total += Double.random(in: 1000...2000, using: &generator)
        }
        return Outcome(mean: total / Double(iterations))
    }
}

@Test func meanIsCentred() throws {
    // WARNING: stochastic-unseeded-test-call
    var sim = MonteCarloSimulation(iterations: 100, enableGPU: true)
    #expect(try sim.run().mean > 1400)
}
```

The checker learns which APIs are seedable by reading `Sources/`: any function or
initializer with a parameter labelled `seed` that has a default value. Nothing to
configure, and nothing to keep in step when a new entry point is added.

Some tests are *about* the unseeded path. Say so, in the same spelling the concurrency
rules use:

```swift
import Testing

func distributionChiSquared(degreesOfFreedom: Int) -> Double {
    (0..<degreesOfFreedom).reduce(0.0) { total, _ in
        let z = Double.random(in: -1...1)
        return total + z * z
    }
}

@Test func nilSeedIsNotReproducible() {
    // Justification: the unseeded path is the contract under test; a seed would invert this
    let a = (0..<20).map { _ in distributionChiSquared(degreesOfFreedom: 5) as Double }
    #expect(a.count == 20)
}
```

The reason is required. A bare `// Justification:` does not suppress — it changes the
diagnostic to say the marker states no reason.

## Configuration

Disable specific rule categories:

```yaml
stochastic-determinism:
  flagCollectionShuffle: false  # skip shuffle checks
  flagGlobalState: false        # skip C-style checks
  auditTests: false             # restore the old Tests/ skip
  flagUnseededTestCalls: false  # skip the omitted-seed rule
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
