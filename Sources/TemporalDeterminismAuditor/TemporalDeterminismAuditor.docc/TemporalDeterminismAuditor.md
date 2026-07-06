# ``TemporalDeterminismAuditor``

Bans hidden nondeterminism sourced from wall-clock time.

## Overview

The Temporal Determinism Auditor is the temporal analog of the
``StochasticDeterminismAuditor``: where that auditor bans nondeterminism from
*randomness*, this one bans nondeterminism from reading the *wall clock* in
places where results must be reproducible.

It exists because of a real regression: a simulation data source
(`SimulationDevice`) stamped every emitted sample with `ContinuousClock.now`.
Because generation was driven by `Task.sleep`, inter-sample spacing tracked
scheduler jitter instead of the intended interval, making a downstream test
flaky. The bug was in production, not the test — so this auditor scans both
`Sources/` (simulated sources) and `Tests/` (timing assertions).

## Rules

| Rule ID | Flags | Severity |
|---|---|---|
| `temporal-simulated-wall-clock` | A wall-clock read (`ContinuousClock.now`, `Date()`, `DispatchTime.now()`, …) stamped as a timestamp value inside a simulation/synthetic/mock/fake/stub type | warning |
| `temporal-wall-clock-assertion` | A test assertion comparing *measured elapsed wall-clock time* against a numeric threshold | warning |

## Exemptions

- Per-line `// temporal:exempt` annotation (both rules)
- `// TIMING:` on an assertion line — declares an intentional wall-clock
  performance test (exempts `temporal-wall-clock-assertion`)
- Types that are not simulation/synthetic/mock-named (a real hardware device may
  legitimately stamp `.now`)
- Configured `exemptTypes`, `exemptFunctions`, `exemptFiles`

## Configuration

```yaml
temporal-determinism:
  exemptTypes: []
  exemptFunctions: []
  exemptFiles: []
  flagSimulatedWallClock: true
  flagWallClockAssertion: true
```

## Topics

### Essentials

- ``TemporalDeterminismAuditor``
