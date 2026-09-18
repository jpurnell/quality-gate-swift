# ``TemporalDeterminismAuditor``

Bans hidden nondeterminism sourced from wall-clock time.

## Overview

The Temporal Determinism Auditor is the temporal analog of the
`StochasticDeterminismAuditor`: where that auditor bans nondeterminism from
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
| `temporal-ambient-calendar` | `Calendar.current`, or `Calendar(identifier:)` with no time zone pinned, in production code | warning |

### The calendar, not the clock

The first two rules are about the *clock*. `temporal-ambient-calendar` is about the
*calendar*, which fails the same way and hides better: a wall-clock read looks like a
wall-clock read, while `Calendar.current` looks like the obvious way to get a calendar.

`Calendar(identifier:)` is the one that matters more. Pinning the identifier fixes the
calendar *system* and inherits `TimeZone.current`, so the site reads as diligence and
survives review while every component it computes still moves with the runner.

Four carve-outs, each earned against real code. A `Calendar(identifier:)` is not ambient
when its zone is pinned by a later statement in the same block, by a statement inside an
`if let` (those initialisers are failable), as a sibling argument of the same call
(`DateComponents(calendar:timeZone:…)`), or — when the calendar is assigned into a receiver
that already exists — by an *earlier* statement, because the `DateFormatter` idiom writes
`dateFormat`, `timeZone`, `locale`, `calendar` in that order. `Calendar.current` gets none
of them: pinning a zone fixes half an ambient calendar, and the system is still the
runner's, so the same instant yields a different year under a Japanese or Buddhist locale.

Scoped to files outside `Tests/`, so it does not double-report what `test-quality`'s
`ambient-calendar-in-test` already owns. The suggested fix names
`Calendar.gregorianUTC` — or `Calendar.iso8601UTC` for week numbers, where the calendar
system changes the answer — both from SwiftDeterminism.

### What counts as a timestamp

The rule fires on an argument label naming a timestamp. Labels match exactly
(`at`, `when`, `time`, `date`, `timestamp`, `instant`, `moment`, `asOf`,
`effective`, …) or on a trailing camelCase component (`executedAt`,
`valuationDate`, `startTime`).

Matching used to be `contains("time")` plus `hasSuffix("at")`, which fired on
`timeout:`, `timeGrid:`, `format:` and `heartbeat:` while missing `asOf:` — a
common spelling for a business-time stamp. A label the checker does not match is
not evidence that a call site is deterministic; add project-specific spellings
via `timestampLabels`.

### What the message says

The diagnostic describes the harm actually present. A stamp inside a loop or a
per-element closure produces a *series*, and the report names sample spacing
tracking scheduler jitter. A single stamp has no spacing to distort, so the
report names non-reproducibility instead: identical inputs yielding a different
result every run. Reporting a mechanism that is not present invites the reader
to dismiss a true finding.

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
  # Extra type-name substrings marking a simulated source, added to the
  # built-in markers. For fabricated sources that are not named "mock"/"fake".
  simulationTypes: []
  # Extra argument labels that count as stamping a timestamp.
  timestampLabels: []
  flagSimulatedWallClock: true
  flagWallClockAssertion: true
  flagAmbientCalendar: true
```

## Topics

### Essentials

- ``TemporalDeterminismAuditor``
