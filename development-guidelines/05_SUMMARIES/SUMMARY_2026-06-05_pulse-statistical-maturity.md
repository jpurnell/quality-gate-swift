# Session Summary: Pulse Statistical Maturity (2026-06-05)

## Problem

The Institutional Pulse produced a single portfolio pass rate (19.7%) against preliminary baselines (n<30), mixing 50 projects at vastly different engagement levels into one number. A project with 2 runs and a project with 246 runs were weighted identically. Binary pass/fail scoring meant a safety failure counted the same as a missing doc comment. Anomaly z-scores lacked validity gates. There was no way to see group-level health for related sub-projects, and pulses were generated weekly with no daily cadence.

## Changes Made

### Phase 1: Foundation Models (IJSSensor)

| File | Purpose |
|------|---------|
| `ProjectTier.swift` | 5-tier engagement classification: dormant (30+ days) < atRisk (21+ days) < firstContact (<3 runs) < baseline < active |
| `SeverityWeight.swift` | 29-checker weight table (safety=1.0 down to disk-clean=0.1) + weighted quality score computation |
| `ProjectTrajectory.swift` | OLS regression model with slope, intercept, r², inflection detection, direction (improving/stable/declining/insufficient) |
| `AnomalyGate.swift` | Validity-gated anomaly escalation: confirmed (valid baseline) / directional (preliminary) / unreliable (insufficient) |
| `ProjectGroup.swift` | Group model with membership lookup |

### Phase 2: Infrastructure + Computation

| File | Change |
|------|--------|
| `CorpusPath.swift` | Added `pulseDirectory(label:)` and `pulsePath(label:)` — old `weekLabel:` methods delegate to new ones |
| `TelemetryWriter.swift` | `writePulse` uses `pulse.label ?? pulse.weekLabel`; `readLatestPulse` sorts chronologically via `parseLabelDate()` |
| `CorpusReader.swift` | `listAvailableLabels()`, `loadPulse(label:)`, chronological sorting for mixed date/week directories |
| `ProjectLifecycle.swift` | Added `groups: [String: [String]]` to `CorpusManifest`, `group(for:)` lookup |
| `GenerateManifest.swift` | New `quality-gate generate-manifest` CLI — scans telemetry, builds manifest.yml, preserves groups on regeneration |
| `InstitutionalPulse.swift` | Added optional `label`, `projectTiers`, `projectTrajectories`, `groupSnapshots` with backward-compatible Codable |
| `PulseStatistics.swift` | Added optional `weightedScores`, `gatedAnomalies` with backward-compatible Codable |
| `PulseRefiner.swift` | Accepts `manifest:` and `label:` params; integrates tier classification, weighted scoring, trajectory computation, anomaly gating, group aggregation |
| `PulseRefiner+Stratification.swift` | `classifyProjects()`, `computeWeightedScores()`, `computeGroupSnapshots()` |
| `PulseRefiner+Trajectory.swift` | `computeTrajectories()` — OLS via BusinessMath, inflection detection for 6+ data points |

### Phase 3: CLI + Display

| File | Change |
|------|--------|
| `GeneratePulse.swift` | `--weekly` flag; defaults to daily date label; loads manifest and passes to refiner |
| `Dashboard.swift` | Uses `loadPulse(label:)`, `pulse.label ?? pulse.weekLabel` for display |
| `DashboardState.swift` | Renamed `availableWeeks` → `availableLabels`, `selectedWeekIndex` → `selectedLabelIndex`, etc. |
| `PulseSectionRenderer.swift` | `renderStratification()`, `renderTrajectories()`, `renderGroupSummary()` |
| `HTMLReportRenderer.swift` | Stratification cards, trajectory table, group pass rate table |
| `PortfolioTUIView.swift` | Label navigator, stratification/trajectory/group sections in pulse view |
| `DashboardRenderer.swift` | Uses `pulse.label ?? pulse.weekLabel` in summary renderer |

### Phase 4: Integration + Quality Gate

- End-to-end integration test: 3 projects at different maturities, manifest with groups, full pipeline + round-trip
- Quality gate: 0 errors, 0 warnings on new code
- First daily pulse generated: `pulse/2026-06-05/PULSE_2026-06-05.json`
- Corpus manifest generated: `manifest.yml` with 50 projects, 5 groups

## First Daily Pulse Results

| Metric | Value |
|--------|-------|
| Label | 2026-06-05 |
| Gate runs | 1,096 |
| Projects | 50 |
| Tier distribution | 38 active, 7 at-risk, 5 first-contact |
| Weighted score range | 0.222–1.000 (mean 0.728) |
| Trajectory directions | 31 improving, 8 declining, 6 stable, 5 insufficient |
| Groups | BusinessMath, Iconquer, Narbis, SwiftExcel, SwiftMCP |
| Gated anomalies | 7 directional (preliminary baselines) |

## Test Results

- 1,787 tests in 228 suites, all passing
- 91 new tests across 13 new test files
- All existing tests pass with no regressions

## Commits

| Hash | Description |
|------|-------------|
| (pending) | Implement Pulse Statistical Maturity: stratification, weighted scoring, trajectories, anomaly gating, project groups, daily pulse |

## Backward Compatibility

- Existing weekly pulse JSON (`PULSE_2026-W19.json`) deserializes without error — `label == nil`, new optional fields absent
- `listAvailableWeeks()` delegates to `listAvailableLabels()` — existing callers work unchanged
- `pulsePath(weekLabel:)` delegates to `pulsePath(label:)` — all existing path computation works
- `PulseRefiner.refine()` new params have defaults — existing callers compile without changes
