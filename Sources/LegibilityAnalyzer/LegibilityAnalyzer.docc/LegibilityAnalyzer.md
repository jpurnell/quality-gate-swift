# ``LegibilityAnalyzer``

Advisory analysis of whole-codebase legibility — can a human (or an agent) pick up the code and build a mental model?

## Overview

Every other checker in quality-gate-swift is a **local-defect detector**: it finds a force-unwrap, a dead function, an unjustified `@unchecked Sendable`. Nothing asked the *whole-codebase* question — is this project **navigable**? The LegibilityAnalyzer is the first checker aimed at that second goal.

It is **advisory-only**, in the mold of the `ComplexityAnalyzer`: every finding is a `.note`, the status is always `.passed`, and it **never gates a commit**. The motivation is empirical — the SonarSource minimal-pair study (arXiv:2605.20049) found that surface cleanliness barely moved task success but cut agent file-revisitation ~34%, and that suppression markers had negligible effect. Only *structure* mattered. So this analyzer reports on structure, and leaves judgment to the reader.

Scope is deliberately bounded against the checkers that already own adjacent ground:

- doc **presence** → `DocCoverageChecker`
- code **deadness** → `UnreachableCodeAuditor`
- local **complexity** → `ComplexityAnalyzer`

The LegibilityAnalyzer owns only the **navigability of live code at module scale**.

## Two graphs

It runs on the **declared** `Package.swift` dependency graph by default — enough to drive module orientation, dependency cycles, and reading order (test targets are filtered out). When a **fresh IndexStore** is present, a semantic pass upgrades that to real reference-weighted fan-in and enables the over-public rule. It degrades cleanly to declared-graph mode when the index is missing or stale — an advisory checker never fails on missing infrastructure.

## Rules

| Rule ID | Flags | Severity |
|---|---|---|
| `legibility.central-unoriented` | A high-fan-in ("load-bearing") module that has **no DocC overview** — coverage ≠ orientation. Ranked; top-N reported. | note |
| `legibility.module-cycle` | A dependency cycle (strongly-connected component) between modules — there is no clean reading order. | note |
| `legibility.over-public-symbol` | A live `public` symbol referenced only within its own module — tighten to `internal`. Requires the IndexStore pass; scoped to public *types* (a public member of a public type is part of that type's contract). | note |

## The reading-order artifact

The analyzer also emits a **module-map / reading-order artifact** under `.build/legibility/` (`legibility-map.json` + `READING_ORDER.md`) — modules ranked by fan-in with their orientation and over-public counts. It is the substrate for a future `ONBOARDING.md` and the dashboard's module-orientation section.

## Exemptions

Legibility is a judgment call, so acknowledgment is surfaced, never silently dropped — **flag to understand, not forbid**:

- `// legibility:reserved` inline marker — acknowledges an intentional over-public symbol (part of a downstream-facing surface). Recorded as a `ComplianceRecord`.
- Configured `exemptSymbols` (fully-qualified names) — same effect, out of band.
- Configured `exemptModules` — drops a module (and every edge into it) from all rules, e.g. generated targets.

## Configuration

```yaml
legibility:
  useIndexStore: true          # semantic pass for real fan-in + the over-public rule
  centralUnorientedTopN: 10    # how many central-but-unoriented modules to report
  minFanInForCentral: 3        # fan-in at which a module is "load-bearing"
  flagOverPublicSymbols: true
  flagCycles: true
  emitReadingOrderArtifact: true
  artifactPath: null           # null → .build/legibility/
  exemptModules: []
  exemptSymbols: []            # e.g. "MyKit.reservedForDownstream"
  reservedMarker: "legibility:reserved"
```

## Topics

### Essentials

- ``LegibilityAnalyzer``
- ``LegibilityAnalyzer/check(configuration:)``
