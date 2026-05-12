# Design Proposal: Stochastic Determinism Auditor

## 1. Problem

Production functions that use randomness without accepting an explicit seed parameter produce non-reproducible results. In financial modeling and simulation code, this violates decision literacy: if a Monte Carlo run produces a surprising result, there's no way to replay it for verification or debugging.

TestQualityAuditor already flags unseeded `SystemRandomNumberGenerator` usage in test files. But the production side is unchecked — a simulation engine can ship with hardcoded `SystemRandomNumberGenerator()` and no seed parameter, making its outputs unreproducible by design.

## 2. Objective

Add a `StochasticDeterminismAuditor` (`stochastic-determinism`) that flags production functions using randomness without providing a seed injection point.

## 3. Proposed Rules

| Rule ID | Flags | Severity |
|---|---|---|
| `stochastic-no-seed` | Function calls `random()`, `.random(in:)`, `.shuffled()`, or instantiates `SystemRandomNumberGenerator` without accepting a generic `RandomNumberGenerator` parameter | warning |
| `stochastic-global-state` | Direct use of `srand48()`, `drand48()`, or `arc4random` family | warning |
| `stochastic-collection-shuffle` | `.shuffled()` or `.shuffle()` without `using:` parameter | warning |

**Exempt patterns (no flag):**
- Functions that accept `inout some RandomNumberGenerator` or generic `<G: RandomNumberGenerator>` parameter
- UUID generation (`UUID()`, `UUID.init()`)
- Cryptographic randomness (`SecRandomCopyBytes`, `CryptoKit`)
- Code inside `Tests/` directories (covered by TestQualityAuditor)
- Functions annotated with `// stochastic:exempt` (for intentionally non-reproducible code like UI jitter)

## 4. Implementation

**Approach:** SwiftSyntax AST visitor walking `Sources/` only.

**Detection strategy:**
1. Walk `FunctionDeclSyntax` nodes, tracking their parameter lists
2. When a randomness API call is found inside a function body, check whether any parameter in the enclosing function signature conforms to `RandomNumberGenerator` (via generic constraint or protocol type)
3. If no such parameter exists, emit diagnostic

**SwiftSyntax limitation:** We can't resolve protocol conformance from syntax alone. Heuristic: check for parameter types containing `RandomNumberGenerator` as a substring, or generic where clauses mentioning `RandomNumberGenerator`. This catches the idiomatic Swift pattern (`using generator: inout some RandomNumberGenerator`).

**Configuration:**
```yaml
stochastic-determinism:
  exemptFunctions: []
  exemptFiles: []
  flagCollectionShuffle: true
  flagGlobalState: true
```

## 5. Implementation Plan

| # | Step | Effort | Dependencies |
|---|---|---|---|
| 1 | Define test cases: functions with/without RNG parameters, exempt patterns | Small | — |
| 2 | Implement `StochasticDeterminismAuditor` with SyntaxVisitor | Medium | SwiftSyntax |
| 3 | Add Configuration extension | Small | QualityGateCore |
| 4 | Register in `allCheckers` | Trivial | Step 2 |
| 5 | DocC catalog (root + guide) | Small | Step 2 |
| 6 | Self-audit: verify quality-gate-swift itself passes | — | Steps 1-5 |

## 6. Success Criteria

- Flags `func simulate() { let x = Double.random(in: 0...1) }` (no seed parameter)
- Passes `func simulate(using rng: inout some RandomNumberGenerator) { let x = Double.random(in: 0...1, using: &rng) }` (seed injectable)
- Does not flag `UUID()` or `SecRandomCopyBytes`
- Does not flag anything in `Tests/`
- quality-gate-swift self-audit passes (quality-gate itself has no production randomness)

## 7. Open Questions

1. **Should this flag `Task.detached` with random delays?** Retry-with-jitter is a legitimate pattern but makes timing non-reproducible. Recommendation: out of scope for v1 — focus on data-producing randomness, not timing.
2. **Should the `using:` parameter be required on collection `.shuffled()` calls?** Recommendation: yes, flag by default, configurable via `flagCollectionShuffle: false`.
3. **Integration with TestQualityAuditor?** Both check randomness but in different scopes (Sources/ vs Tests/). Keep separate — they have different rules and exemption logic.

---

**Date:** 2026-04-29
**Author:** Justin Purnell + Claude Opus 4.6
