# Design Proposal: IJS Dashboard

**Date:** 2026-05-15
**Status:** Proposed
**Author:** Claude (AI Assistant)

---

## Problem Statement

The IJS telemetry corpus accumulates JSON metadata on every quality-gate run — per-checker results, durations, overrides, risk tiers, consistency scores, and ethical flags. This data exists but is invisible. There is no way to visualize trends, compare projects, or spot regressions without manually reading JSON files.

The [org-judgement-system Master Plan](../../../org-judgement-system/development-guidelines/00_CORE_RULES/00_MASTER_PLAN.md) defines a four-layer feedback loop (Sensor → Aggregator → Refiner → Loop) but has no visualization layer. The [P2 CrossProjectCorpus proposal](../UPCOMING/P2_CrossProjectCorpus.md) formalizes a git-backed corpus with per-project branches and daily merge to `main`. The dashboard is the missing fifth layer that makes all of this visible.

The dashboard surfaces the data at two levels:

1. **Portfolio view** — across all projects in the corpus (reads from `main` branch of the org-judgement-corpus repo), showing organizational health
2. **Project view** — drill-down into a single project's history and trends (reads from `project/<id>` branch or local `.ijs-corpus/`)

### Why Now

- The corpus is live — telemetry writes on every `quality-gate` run with `corpusPath` configured
- The P2 CrossProjectCorpus proposal defines the git-backed multi-project corpus with per-project branches — the portfolio data source is designed
- SwiftCLIKit already provides terminal UI widgets (BarChart, Sparkline, Table, Tabs, Gauge, Tree) that map directly to dashboard needs
- The OJS Master Plan identifies "Cross-project violation cluster analysis" as a future consideration — the portfolio view delivers this
- Starting with terminal means zero deployment friction — runs anywhere quality-gate runs

### Relationship to OJS Master Plan

This proposal implements **Phase 5: Visualization** of the Institutional Judgment System, sitting atop all four existing layers:

```
Phase 5: Dashboard (this proposal)
    ↑ reads from
Phase 4: Loop (PolicyDiscoveryAuditor, ConsistencyChecker)
    ↑ reads Pulse
Phase 3: Refiner (PulseRefiner — weekly Pulse generation)
    ↑ reads merged telemetry
Phase 2: Aggregator (CorpusManager — git clone/pull/push)
    ↑ pushes to project branches
Phase 1: Sensor (CheckResultMetadata — local telemetry capture)
```

The dashboard serves three of the four OJS target users directly:
- **Decision Owners** — portfolio view to exercise approval authority
- **Practitioners** — project view to see their own trends and regressions
- **AI Agents** — `--format json` output for MCP consumption

---

## Proposed Solution

### Architecture: Two-Phase Build

**Phase 1: Terminal Dashboard (SwiftCLIKit)**
A new executable target `quality-gate-dashboard` that reads the IJS corpus and renders an interactive terminal UI using SwiftCLIKit.

**Phase 2: SwiftUI Dashboard (all platforms)**
A shared `IJSDashboardCore` library with platform-agnostic view models, consumed by a SwiftUI app targeting macOS, iOS, iPadOS, and visionOS.

Both phases share the same data layer — only the rendering differs.

### Module Structure

```
Sources/
├── IJSDashboardCore/           # Shared data layer (Phase 1+2)
│   ├── CorpusReader.swift      # Read/parse .ijs-corpus JSON files
│   ├── ProjectSummary.swift    # Per-project aggregated metrics
│   ├── PortfolioSummary.swift  # Cross-project rollup
│   ├── TrendComputer.swift     # Time-series analysis (pass rate, duration, score)
│   └── DashboardViewModel.swift # Observable state for both terminal and SwiftUI
│
├── IJSDashboardCLI/            # Terminal dashboard (Phase 1)
│   ├── DashboardApp.swift      # SwiftCLIKit App entry point
│   ├── PortfolioView.swift     # Multi-project overview (Table + Sparklines)
│   ├── ProjectDetailView.swift # Single-project deep dive
│   ├── CheckerHeatmap.swift    # Checker × date pass/fail grid
│   └── TrendChart.swift        # BarChart/Sparkline for time series
│
└── IJSDashboardUI/             # SwiftUI dashboard (Phase 2)
    ├── PortfolioView.swift     # Charts framework + SwiftUI
    ├── ProjectDetailView.swift
    └── IJSDashboardApp.swift
```

### Phase 1: Terminal Dashboard Detail

#### Data Layer (IJSDashboardCore)

**CorpusReader** supports two data sources, matching the P2 CrossProjectCorpus proposal:

1. **Git-backed corpus** (portfolio view) — clones/pulls the `org-judgement-corpus` repo via `CorpusManager` from P2. Reads from `main` (merged cross-project state) for the portfolio view, or `project/<id>` for a single-project view.
2. **Local corpus** (project view) — reads from `.ijs-corpus/` in the project root when no remote is configured.

Both share the same directory structure:

```
org-judgement-corpus/  (or .ijs-corpus/)
├── telemetry/
│   ├── quality-gate-swift/
│   │   └── 2026-05-15/
│   │       ├── 050024_metadata.json
│   │       ├── 050048_metadata.json
│   │       └── 050225_metadata.json
│   └── another-project/
│       └── 2026-05-14/
│           └── 143022_metadata.json
├── snapshots/
│   └── quality-gate-swift/
│       └── 2026-05-15.json
└── pulse/
    └── 2026-W20/
        └── PULSE_2026-W20.json
```

The git-backed corpus has per-project branches (`project/quality-gate-swift`, etc.) with daily merge to `main` via GitHub Actions cron. The dashboard reads from `main` for the organizational view — this is the single merged snapshot of all projects' telemetry.

Each JSON file is a `CheckResultMetadata` — the same struct IJSSensor already defines. CorpusReader decodes them into `[ProjectID: [TimestampedRun]]`. It also reads Pulse documents from `pulse/` to overlay trend annotations ("violation cluster detected in week 20").

**ProjectSummary** aggregates per-project:
- Latest run status (pass/fail)
- Pass rate over last N runs
- Checker-level breakdown (which checkers fail most)
- Average duration trend
- Override count and frequency
- Risk tier

**PortfolioSummary** rolls up across projects:
- Total projects tracked
- Projects passing vs failing
- Worst-performing checkers across the portfolio
- Risk tier distribution
- Consistency score distribution (when available)

**TrendComputer** produces time-series data:
- Daily/weekly pass rate
- Duration trends (are builds getting slower?)
- New violation introduction rate
- Override accumulation (are teams suppressing instead of fixing?)

#### Terminal UI (IJSDashboardCLI)

Uses SwiftCLIKit widgets:

| View | Widgets Used | Data Source |
|------|-------------|-------------|
| Portfolio overview | `Table` + `InlineSparkline` + `Gauge` | PortfolioSummary |
| Project list | `List` with status indicators | ProjectSummary[] |
| Project detail | `Tabs` (Overview / Checkers / Trends / Overrides) | ProjectSummary |
| Checker breakdown | `BarChart` (pass/fail by checker) | CheckerStats |
| Trend view | `Sparkline` (pass rate over time) | TrendComputer |
| Override audit | `Table` (rule, file, justification, frequency) | OverrideStats |
| Risk tier summary | `Gauge` per tier | PortfolioSummary |

**Navigation:**
- Arrow keys to select project from portfolio view
- Enter to drill into project detail
- Tab key to switch between detail tabs
- `q` to go back / exit
- `/` to filter projects by name

**CLI integration:**
```bash
# Interactive dashboard — local corpus (project view only)
quality-gate dashboard

# Interactive dashboard — git-backed corpus (portfolio + project views)
quality-gate dashboard --corpus-url git@github.com:jpurnell/org-judgement-corpus.git

# One-shot summary (CI-friendly, no interactivity)
quality-gate dashboard --summary

# Specific project drill-down
quality-gate dashboard --project quality-gate-swift

# Portfolio report as JSON (for piping to other tools)
quality-gate dashboard --format json

# Read corpus URL from .quality-gate.yml (consistency.corpusURL)
quality-gate dashboard --portfolio
```

Registered as a subcommand of quality-gate via ArgumentParser. When `consistency.corpusURL` is configured in `.quality-gate.yml`, the dashboard uses `CorpusManager` from P2 to clone/pull the remote corpus automatically.

### Phase 2: SwiftUI Dashboard Detail

Shares `IJSDashboardCore` view models. Uses Swift Charts for visualizations. Targets:

- **macOS** — menu bar app or standalone window
- **iOS/iPadOS** — read corpus from iCloud Drive or shared volume
- **visionOS** — spatial layout for portfolio overview

The SwiftUI layer is a separate package/target to avoid pulling SwiftCLIKit into GUI builds and vice versa.

Phase 2 is out of scope for this proposal — it gets its own proposal once Phase 1 ships.

---

## Constraints & Compliance

- **Concurrency:** `CorpusReader` and `TrendComputer` are `Sendable`. View models use `@Observable` (SwiftUI) or value types (terminal).
- **Safety:** No force unwraps. JSON decoding uses `try?` with skip-and-warn for corrupt files.
- **Determinism:** Pure computation over JSON files — no network, no randomness.
- **Performance:** Corpus reads are lazy (scan directory, decode on demand). For portfolios with hundreds of projects, only summaries are held in memory.
- **Floating-point:** All score comparisons use `abs(a - b) < 1e-6`, never `==`.

## Documentation Strategy

- **Type:** Tutorial + API Docs
- Tutorial: "Reading Your Quality Dashboard" — what each metric means, how to interpret trends
- API docs on all public types in IJSDashboardCore

---

## Integration

### Package.swift Changes
- New library: `IJSDashboardCore` (depends on `IJSSensor` for `CheckResultMetadata`, `IJSAggregator` for `CorpusPath`)
- New executable: `IJSDashboardCLI` (depends on `IJSDashboardCore`, `SwiftCLIKit`)
- New test target: `IJSDashboardCoreTests`
- SwiftCLIKit added as a package dependency (github.com/jpurnell/SwiftCLIKit)

### CLI Registration
- `quality-gate dashboard` subcommand via ArgumentParser
- Subcommand flags: `--summary`, `--project <id>`, `--format json|terminal`, `--corpus <path>`, `--corpus-url <git-url>`, `--portfolio`

### Dependencies on Other Proposals

| Dependency | Required For | Status |
|---|---|---|
| P2 CrossProjectCorpus (`CorpusManager`) | Portfolio view (git clone/pull of remote corpus) | Proposed — not yet implemented |
| IJSSensor (`CheckResultMetadata`) | Decoding telemetry JSON | Implemented |
| IJSAggregator (`CorpusPath`) | Directory structure navigation | Implemented |
| SwiftCLIKit | Terminal UI rendering | Available at github.com/jpurnell/SwiftCLIKit |

**Note:** The project-level view works today with the local `.ijs-corpus/` directory. The portfolio view requires P2's `CorpusManager` for the git-backed remote corpus. Phase 1 can ship the project view immediately and add the portfolio view when P2 lands.

---

## Testing Plan

### Unit Tests (IJSDashboardCoreTests)

1. CorpusReader discovers projects from directory structure
2. CorpusReader decodes valid metadata JSON
3. CorpusReader skips malformed JSON with warning
4. CorpusReader handles empty corpus directory
5. ProjectSummary computes pass rate correctly
6. ProjectSummary identifies worst-performing checker
7. PortfolioSummary aggregates across projects
8. TrendComputer produces correct time-series for daily pass rate
9. TrendComputer handles single-run projects (no trend)
10. TrendComputer duration trend detects slowdowns

### Integration Test
- Populate a test corpus with known JSON files
- Run `quality-gate dashboard --summary --corpus <test-corpus>`
- Verify output contains expected project names and pass rates

### Snapshot Tests (Terminal UI)
- Use SwiftCLIKit's `TestBackend` + `SnapshotTesting` for deterministic rendering
- Portfolio view with 3 projects renders expected table
- Project detail tabs render expected content

---

## Adversarial Review

### False Positives — What would this report incorrectly?

1. **Stale runs inflate failure rate.** If a project had 10 failures a month ago and 0 today, the dashboard shows a low pass rate unless filtered to a time window. **Mitigation:** Default to last 30 days. Show "latest run" prominently alongside trend.

2. **Override counts conflate suppression with exemption.** A project with 50 `// SAFETY:` comments looks override-heavy but may be fully justified. **Mitigation:** Show override-by-rule breakdown, not just count. Let users mark exemptions as "reviewed" in the corpus.

3. **Duration spikes from cold builds.** A single slow run (clean build, no cache) skews the average. **Mitigation:** Use median instead of mean for duration trends. Flag outliers.

### False Negatives — What would this miss?

1. **Projects not in the corpus.** If a project doesn't configure `corpusPath`, the dashboard has no data for it. This is invisible — you don't know what you don't know. **Mitigation:** Document corpus configuration in the HOWTO. The portfolio view could show "N projects tracked" as a reminder.

2. **Checker-specific regressions hidden by overall pass rate.** A project passing 24/25 checkers looks green, but if `concurrency` has failed the last 5 runs, that's a regression the portfolio view might not surface. **Mitigation:** Per-checker trend sparklines in the project detail view. Portfolio view highlights "consistently failing" checkers.

3. **Cross-project patterns.** If 8 out of 10 projects fail `fp-safety`, that's a systemic issue — but per-project views won't surface it. **Mitigation:** Portfolio view includes "worst checkers across portfolio" rollup.

### Evasion — How could someone game the metrics?

1. **Run quality-gate on a clean branch.** The corpus doesn't know which branch was checked. Telemetry from `main` and a feature branch look the same. **Mitigation:** The metadata includes `environment` (local vs CI). CI runs are authoritative. Future: add git branch/commit to metadata.

2. **Delete old failure records.** Someone could remove JSON files from the corpus to improve history. **Mitigation:** Git tracks the corpus. Deleted files are visible in git log. For append-only guarantees, the P2 Cross-Project Corpus proposal covers a centralized store.

### Performance Impact

- Corpus with 1,000 JSON files (~100 projects × 10 runs each): <2 seconds to scan and summarize.
- Corpus with 10,000 files: may need indexing. Phase 1 targets <1,000 files. Phase 2 introduces SQLite or append-only log if needed.

### Scope Limitation

- Phase 1 is terminal-only. No web UI, no hosted dashboard.
- The dashboard is read-only — it does not modify the corpus or trigger quality-gate runs.
- No authentication or multi-user access in Phase 1.

---

## Alternatives Considered

### 1. Web dashboard (HTML/JS)
Rejected for Phase 1: adds a web server dependency, deployment complexity, and a second language. Terminal-first means zero friction — runs anywhere quality-gate runs.

### 2. Grafana / external dashboards
Rejected: requires infrastructure (Prometheus, InfluxDB). The corpus is local JSON files. An external tool that reads them adds operational overhead disproportionate to the value at this stage.

### 3. quality-gate --format dashboard (inline in CLI output)
Rejected: the current CLI output is per-run. A dashboard needs multi-run, multi-project data. Mixing them in the same output path would complicate both.

### 4. SwiftUI only (skip terminal)
Rejected: terminal-first ensures the dashboard works in CI, SSH sessions, and headless environments. SwiftCLIKit's TestBackend enables snapshot testing of the UI. SwiftUI is Phase 2, not a replacement.

---

## Implementation Order

1. Design proposal (this document)
2. `IJSDashboardCore` — CorpusReader, ProjectSummary, PortfolioSummary, TrendComputer (RED/GREEN)
3. `IJSDashboardCLI` — SwiftCLIKit app with portfolio and project views (RED/GREEN)
4. CLI subcommand registration in QualityGateCLI
5. Snapshot tests for terminal views
6. Documentation: tutorial + API docs
7. Phase 2 proposal: SwiftUI dashboard (separate document)
