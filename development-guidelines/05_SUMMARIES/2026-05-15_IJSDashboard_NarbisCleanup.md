# Session Summary: IJS Dashboard TUI & Narbis Workspace Cleanup

**Date:** 2026-05-15  
**Branch:** main  
**Scope:** IJS Dashboard TUI, narbis workspace compliance, floating-point auditor, corpus onboarding

---

## What Happened

### 1. IJS Dashboard TUI (New Feature)

Built a full-screen interactive terminal dashboard for viewing quality-gate health across all Swift projects in the org-judgement-corpus. Invoked via `quality-gate dashboard`.

**Modules added:**
- `IJSDashboardCore` — data layer: `CorpusReader`, `ProjectSummary`, `PortfolioSummary`, `TrendComputer`
- `IJSDashboardCLI` — rendering: portfolio view, project detail view (Overview/Checkers/Trends tabs), keyboard/mouse navigation

**Key capabilities:**
- Portfolio view with per-run health timeline (10-cell gradient: green/yellow/orange/red based on checker pass rate per run), project status, scroll support
- Project detail with tabbed navigation (Overview, Checkers, Trends)
- Checker tab shows ✓/× for current pass/fail status and a red/green ratio bar showing historical pass rate
- Sparkline trend charts for daily pass-rate history
- Mouse support (click to select, scroll wheel)
- Live reload every 30 seconds — corpus re-read without restart, new projects appear automatically
- JSON output mode (`--output-format json`), one-shot summary (`--summary`)

**CLI commands added:**
- `quality-gate dashboard` — interactive TUI (default) or `--summary`/`--output-format json`
- `quality-gate generate-pulse` — generates IJS pulse from corpus data

**Platform bumped to macOS 15** (SwiftCLIKit dependency requires it).

### 2. Narbis Workspace Cleanup (8 Packages)

Brought all 8 narbis sub-packages to quality-gate compliance:
- BioFeedbackKit, BFK-EdgeBLE, BFK-HealthKit, BFK-HRBLE, BFK-Polar
- EdgeSDK-Swift, NarbisUI, NarbisWatchKit

**Work done per package:**
- Bumped swift-tools-version to 6.3
- Added `.quality-gate.yml` with consistency config and overrides for false positives
- Fixed doc-coverage (100% across all packages)
- Added privacy annotations, fp-safety guards, justification comments
- Created README.md and CHANGELOG.md for BFK packages (release-readiness)
- Fixed test tolerance issues (floating-point exact comparisons)

**174 files committed and pushed** to `narbisEdge` main.

### 3. Floating-Point Auditor Improvements

- Extended guarded-variable collection to initializer bodies
- Recognizes `!collection.isEmpty` as a count > 0 guard
- Allows member-access expressions (e.g. `self.x`) in denominator tracking

### 4. Dashboard Bug Fixes (Three Rounds)

**Round 1 — Checker indicators:** Changed from rate-based (× when historical rate < 100%) to latest-run-based. Added `latestCheckerPassed: [String: Bool]` field to `ProjectSummary`.

**Round 2 — Per-checker latest run:** Partial runs (e.g. single-checker release-readiness) as the latest run caused false × for all other checkers. Fixed by scanning runs newest-to-oldest and using the most recent run *per checker*.

**Round 3 — Gauge redesign:** Replaced opaque `InlineGauge` percentage bar with a red/green ratio bar. Each cell is proportional: a 40% pass rate shows 9 red blocks then 6 green blocks.

**Round 4 — Portfolio health timeline:** Replaced single-cell status icon with a 10-cell per-run gradient in the portfolio view. Each cell represents one quality-gate run (most recent on right). Color encodes the percentage of checkers passing in that run: green (90%+), yellow (75%+), orange (60%+), red (<60%). Runs fewer than 10 show dim `─` padding on the left.

**Other fixes:**
- Portfolio scroll follow — selection stays visible when navigating with arrow keys or page up/down
- Live reload — `poll()` on stdin with 500ms timeout, corpus re-read every 30s

### 5. Corpus Onboarding

- Corpus path moved from local `.ijs-corpus` to shared `org-judgement-corpus`
- Created `scripts/onboard-corpus.sh` — batch onboard script for all Swift projects
- 44 projects now emitting telemetry to the shared corpus
- 5 design proposals moved from PROPOSALS/ to COMPLETED/
- Master plan updated with dashboard modules

---

## Commits (chronological)

| Hash | Description |
|------|-------------|
| `edc29aa` | feat: add IJS modules, ProcessRunner deadlock fix, enforcement infrastructure |
| `77e4485` | fix: improve floating-point auditor |
| `bf0c557` | feat: IJS dashboard TUI — interactive portfolio and project detail views |
| `008c887` | chore: update quality-gate config — add docTarget, use org-judgement-corpus |
| `77f6254` | chore: move implemented proposals to COMPLETED, update master plan |
| `bb24801` | feat: add corpus onboarding script for batch project setup |
| `6f12a03` | fix: checker indicators use per-checker latest run; add live reload |
| `d4b1b15` | feat: replace checker gauge with pass/fail ratio bar |
| `131d325` | docs: session summary, handoff doc, gitignore stale corpus |
| `7ce9e00` | feat: portfolio health timeline — per-run gradient showing checker pass rate |

---

## Known Issues / Next Steps

- **NarbisUI accessibility warnings:** 32 warnings (fixed fonts, tap targets, animations) — not quality-gate blockers
- **EdgeSDK-Swift, NarbisWatchKit:** `release-readiness: info` overrides — could add README/CHANGELOG
- **Dashboard text-mode renderer:** `DashboardRenderer.renderProjectDetail` still uses rate-based indicator (only affects `--summary`, not TUI)
- **P2 Cross-Project Corpus:** Remote git-backed corpus with per-project branches — approved, not started
- **P3a CI-Native Telemetry Push:** GitHub Actions workflow — approved, not started
- **P3b IJS MCP Tools:** query_pulse, record_calibration, etc. — approved, not started

---

## Architecture Notes

The dashboard reads telemetry from the file-based corpus at:
```
org-judgement-corpus/telemetry/<project>/<date>/<timestamp>_metadata.json
```

Each JSON file is a `CheckResultMetadata` containing `[CheckResult]` with checker IDs and pass/fail status. `ProjectSummary.compute()` aggregates these into per-checker pass rates and per-checker latest status (scanning newest run first per checker).

The TUI renders using SwiftCLIKit primitives (ScreenBuffer, BoxDrawing, InlineSparkline). The portfolio view shows a 10-cell health timeline per project — each cell is a full-block character colored by that run's checker pass rate (green/yellow/orange/red gradient). The checker detail tab uses a red/green ratio bar proportional to historical pass rate.

Live reload uses POSIX `poll()` on stdin with a 500ms timeout. When no input arrives and 30 seconds have elapsed, the corpus is re-read and summaries recomputed. `DashboardState.updateProjectIDs()` preserves the current selection across reloads.

Binary installed at `/usr/local/custom/bin/quality-gate`. After editing, rebuild with:
```
swift build -c release && sudo cp .build/release/quality-gate /usr/local/custom/bin/quality-gate && sudo codesign --force --sign - /usr/local/custom/bin/quality-gate
```
