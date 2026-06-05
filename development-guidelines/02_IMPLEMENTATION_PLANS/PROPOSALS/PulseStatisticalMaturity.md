# Design Proposal: Pulse Statistical Maturity

**Objective:** Replace the single portfolio pass rate with a layered statistical model that stratifies projects by engagement level, scores gate failures by severity rather than binary pass/fail, gates anomaly detection on baseline maturity, and tracks per-project trajectories as the primary health signal. These four capabilities interact: stratification determines which projects feed the baseline, severity weighting replaces the binary metric that the baseline is computed against, trajectory analysis depends on weighted scores to detect real movement vs. noise, and anomaly detection trusts its own z-scores only when the baseline is mature enough to support them.

**Master Plan Reference:** Institutional Pulse — statistical infrastructure hardening.

---

## 1. Motivation

The current pulse computes a single portfolio pass rate (19.7% across 1,092 runs / 50 projects) and runs anomaly detection against baselines with n=15 samples. Four problems:

1. **The pass rate mixes unmeasured projects with actively maintained ones.** A project that has never been remediated fails every run — that's not health data, it's a to-do list. Mixing it with BusinessMath (which just reached 0/0) produces a number that doesn't describe either population.

2. **Pass/fail is binary, but failures aren't equivalent.** A project that fails only on doc-coverage is in a fundamentally different state than one failing on safety + concurrency + test-quality. The current model treats them identically: both count as 1 failure.

3. **Anomaly detection doesn't know when to trust itself.** The z-score machinery runs with `validity: preliminary` (n=15), producing confidence intervals that span impossible values (passRate CI₉₅ from -0.27 to 1.03). The system flags anomalies and attaches a `validity` label, but doesn't adjust its behavior — a z=3.36 anomaly against a preliminary baseline triggers the same `extreme` severity as one against an established baseline.

4. **Per-project trajectory is the real signal, but it's buried.** The narrative manually interprets project snapshot arrays. There's no computed trend direction, no inflection detection, no way to answer "which projects are improving vs. degrading?" without reading raw snapshot data.

These four problems interact. You can't compute a meaningful portfolio pass rate until you stratify. You can't stratify meaningfully on binary pass/fail because the boundary is too coarse — severity weighting gives you a continuous signal. You can't trust anomaly detection until baselines mature, and baselines computed from unstratified binary pass rates mature slowly because they're noisy. Fixing any one in isolation helps; fixing all four as a unified system produces compounding returns.

---

## 2. Proposed Architecture

All new types live in `IJSSensor` (model layer). Computation moves into `IJSRefiner` (where `PulseRefiner` already lives). Dashboard rendering extends the existing `PulseSectionRenderer` and `HTMLReportRenderer`.

**New Files:**
- `Sources/IJSSensor/ProjectTier.swift` — stratification model
- `Sources/IJSSensor/SeverityWeight.swift` — checker severity weights and weighted score model
- `Sources/IJSSensor/ProjectTrajectory.swift` — per-project trajectory analysis
- `Sources/IJSSensor/AnomalyGate.swift` — validity-gated anomaly decisions

**Modified Files:**
- `Sources/IJSSensor/PulseStatistics.swift` — add stratified statistics, weighted scores
- `Sources/IJSSensor/InstitutionalPulse.swift` — add `stratifiedStatistics` field, rename `weekLabel` to `label`
- `Sources/IJSSensor/StatisticalAnomaly.swift` — add `gatedSeverity` field
- `Sources/IJSRefiner/PulseRefiner.swift` — compute stratification, weighting, trajectories; replace `isoWeekLabel` with `dateLabel`
- `Sources/IJSAggregator/CorpusPath.swift` — generalize `pulseDirectory(weekLabel:)` → `pulseDirectory(label:)`
- `Sources/IJSAggregator/TelemetryWriter.swift` — update `writePulse`/`readLatestPulse` for date-labeled directories
- `Sources/IJSDashboardCore/CorpusReader.swift` — update `listAvailableWeeks` → `listAvailableLabels`, handle both date and week formats
- `Sources/IJSDashboardCLI/PulseSectionRenderer.swift` — render stratified view, use `label` not `weekLabel`
- `Sources/IJSDashboardCLI/HTMLReportRenderer.swift` — render stratified HTML, display date with optional week context
- `Sources/IJSDashboardCLI/DashboardRenderer.swift` — update label display
- `Sources/IJSDashboardCLI/PortfolioTUIView.swift` — update week navigator to handle both formats
- `Sources/IJSDashboardCLI/DashboardState.swift` — rename `availableWeeks` → `availableLabels`
- `Sources/QualityGateCLI/GeneratePulse.swift` — default to daily; add `--weekly` flag for backward compatibility
- `Sources/QualityGateCLI/Dashboard.swift` — replace `isoWeekLabel` helper with `dateLabel`

**Module Placement:** No new modules. Types compose into the existing IJSSensor → IJSRefiner → IJSDashboardCLI pipeline.

### 2.1 Infrastructure: Weekly → Daily Label Migration

The current system threads the label as an opaque string through 14 call sites. The label is computed once in `PulseRefiner.isoWeekLabel(for:)` and consumed everywhere else. The migration replaces the computation and generalizes the plumbing.

**Label computation change:**

```swift
// Before (PulseRefiner.swift:423-431)
private func isoWeekLabel(for date: Date) -> String {
    // produces "2026-W23"
}

// After
private func dateLabel(for date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return formatter.string(from: date).prefix(10).description
    // produces "2026-06-04"
}
```

**Path generalization:**

```swift
// Before (CorpusPath.swift:63-71)
public func pulseDirectory(weekLabel: String) -> String
public func pulsePath(weekLabel: String) -> String

// After — rename parameter, logic unchanged
public func pulseDirectory(label: String) -> String
public func pulsePath(label: String) -> String
```

**Directory discovery (backward compatibility):**

```swift
// CorpusReader.swift — listAvailableLabels
// Scans pulse/ for subdirectories. Both "2026-W23" and "2026-06-04"
// sort lexicographically in the correct temporal order because:
//   "2026-06-04" > "2026-W23" (digit > letter 'W')
// This means daily labels sort AFTER weekly labels, which is correct:
// daily pulses are newer than the last weekly pulse.
// No special handling needed — lexicographic sort works for both formats.
```

**Dashboard display:**

The dashboard header shows the label as-is. For daily labels, this is `Pulse 2026-06-04`. For old weekly labels, this is `Pulse 2026-W23`. No format translation needed — the label is self-describing.

To show the ISO week for context on daily labels, the HTML header adds a subtitle:

```swift
// HTMLReportRenderer.swift
let subtitle: String
if label.contains("W") {
    subtitle = ""  // weekly label is self-explanatory
} else {
    let weekLabel = isoWeekLabel(for: pulse.windowStart)
    subtitle = " (\(weekLabel))"
}
// renders: "Pulse 2026-06-04 (2026-W23)"
```

The TUI navigator (`PortfolioTUIView.renderWeekNavigator`) works unchanged — it iterates over `availableLabels` (renamed from `availableWeeks`) and displays whatever string is there. The left/right arrow navigation is index-based, not format-dependent.

**Corpus directory structure after migration:**

```
pulse/
  2026-W16/PULSE_2026-W16.json          # historical weekly
  2026-W17/PULSE_2026-W17.json
  ...
  2026-W23/PULSE_2026-W23.json          # last weekly pulse
  2026-06-05/                            # first daily pulse
    PULSE_2026-06-05.json
    DIGEST_2026-06-05.md
  2026-06-06/
    PULSE_2026-06-06.json
    DIGEST_2026-06-06.md
  2026-W24/                              # weekly narrative (generated from daily data)
    NARRATIVE_2026-W24.md
```

Weekly narrative directories coexist with daily pulse directories. The navigator shows all of them in sorted order. Weekly narratives are written manually (or by LLM) — they don't contain a pulse JSON, just the narrative markdown.

---

## 3. API Surface

### 3.1 Project Stratification

```swift
/// Classifies a project's engagement level with the quality gate.
public enum ProjectTier: String, Sendable, Codable, Comparable {
    /// Actively maintained against the gate. Has recent runs with intentional remediation.
    case active
    /// Gated but not actively remediated. Runs exist but pass rate is flat at floor.
    case baseline
    /// Measured for the first time this window. No prior history.
    case firstContact
    /// Most recent run is 21–30 days old. Tickle warning before dormancy.
    case atRisk
    /// No gate runs in the trailing 30-day window (but historical telemetry exists).
    case dormant
}

public struct TierClassification: Sendable, Codable, Equatable {
    public let projectID: String
    public let tier: ProjectTier
    public let reason: String
    public let runCount: Int
    public let windowPassRate: Double
    public let trajectorySlope: Double?
}

public struct StratifiedStatistics: Sendable, Codable, Equatable {
    public let tiers: [ProjectTier: TierStatistics]
    public let activePortfolioPassRate: Double
    public let activePortfolioWeightedScore: Double
    public let classifications: [TierClassification]
}

public struct TierStatistics: Sendable, Codable, Equatable {
    public let projectCount: Int
    public let totalRuns: Int
    public let passedRuns: Int
    public let passRate: Double
    public let weightedScore: Double
    public let meanWeightedScore: Double
}
```

**Classification rules** (computed by `PulseRefiner`, evaluated against the trailing 30-day classification window):

| Condition | Tier |
|---|---|
| ≥3 runs in 30-day window AND (pass rate improved ≥10pp OR latest run passed OR trajectorySlope > 0) | `active` |
| ≥3 runs in 30-day window AND pass rate flat (slope ≈ 0 within ±0.01) AND pass rate < 50% | `baseline` |
| 1–2 runs in 30-day window (not enough data for trajectory) | `firstContact` |
| Most recent run is 21–30 days ago | `atRisk` (tickle) |
| 0 runs in 30-day window (but historical telemetry exists) | `dormant` |

**Dormant tickle:** The `atRisk` tier is a transitional state — a project whose most recent gate run is 21+ days old but still within the 30-day window. It functions as a 9-day warning before dormancy. At-risk projects:
- Still participate in statistical computation (they have recent-ish data)
- Generate a tickle alert in the daily digest: "ProjectX last gated 23 days ago — goes dormant in 7 days"
- Automatically transition to `dormant` if no new gate run appears before the 30-day cutoff
- Automatically transition back to `active`/`baseline`/`firstContact` if a new gate run lands

The tickle is surfaced in the daily digest under a dedicated section, making it easy to decide: gate the project intentionally, or let it go dormant. No action required — dormancy is the natural default if the project isn't being worked on.

The tier classification is deterministic from snapshot data — no manual tagging required. A project transitions between tiers automatically as its run history changes.

**Interaction with other components:**
- Anomaly detection baselines are computed from `active` tier projects only (avoids noise from `baseline` and `firstContact`).
- The portfolio headline metric becomes `activePortfolioWeightedScore`, not `passRate`.
- Per-project trajectories are computed for `active` and `baseline` tiers; `firstContact` projects get a "pending" trajectory.

### 3.2 Severity-Weighted Scoring

```swift
/// Severity weight for a checker category.
/// Higher weight = more impactful failure.
public struct CheckerWeight: Sendable, Codable, Equatable {
    public let checkerId: String
    public let weight: Double
    public let rationale: String
}

/// Default weights derived from the checker's risk domain.
/// These are not configurable per-project — they reflect the
/// institutional view of what matters.
public enum SeverityWeight: Sendable {
    /// Returns the default weight for a checker ID.
    /// Weight range: 0.0 (informational) to 1.0 (critical).
    public static func defaultWeight(for checkerId: String) -> Double

    /// All default weights with rationale.
    public static var defaults: [CheckerWeight] { get }
}

public struct WeightedGateScore: Sendable, Codable, Equatable {
    public let projectID: String
    public let date: Date
    public let rawPassRate: Double
    public let weightedScore: Double
    public let failingCheckerWeights: [String: Double]
    public let maxPossibleScore: Double
}
```

**Default weight table:**

| Checker | Weight | Rationale |
|---|---|---|
| safety | 1.0 | Path traversal, command injection, insecure transport — correctness and security |
| concurrency | 1.0 | Data races, Sendable violations — correctness under concurrency |
| pointer-escape | 1.0 | Use-after-free, dangling pointers — memory safety |
| recursion | 0.9 | Infinite recursion — runtime crash |
| test-quality | 0.8 | Weak assertions, missing assertions — test effectiveness |
| test | 0.8 | Test compilation/execution failures — test infrastructure |
| build | 0.8 | Compilation failures — project health |
| logging | 0.5 | Silent error swallowing — observability |
| process-safety | 0.5 | Process-level safety — operational |
| dependency-audit | 0.5 | Hallucinated imports, unused deps — build hygiene |
| unreachable | 0.3 | Dead code — code hygiene, not correctness |
| doc-coverage | 0.2 | Missing documentation — quality of life |
| doc-lint | 0.2 | Malformed docs — quality of life |
| swift-version | 0.3 | Version compatibility — forward-looking |
| status | 0.1 | Status reporting — informational |
| consistency | 0.1 | Cross-run consistency — informational |
| hig-auditor | 0.3 | UI guideline compliance — platform quality |

**Scoring formula:**

```
weightedScore = 1.0 - (sum of weights of failing checkers) / (sum of weights of all checkers that ran)
```

A project where only `doc-coverage` (0.2) fails out of 10 checkers with total weight 6.0 scores `1.0 - 0.2/6.0 = 0.967`. A project where `safety` (1.0) + `concurrency` (1.0) + `test-quality` (0.8) fail scores `1.0 - 2.8/6.0 = 0.533`. Both are "failures" in binary pass/fail; the weighted score distinguishes them.

**Interaction with other components:**
- The weighted score replaces binary pass rate as the input to trend analysis. `TrendAnalysis` computed on weighted scores has lower variance than on binary pass rates, which means baselines reach `valid` status faster (fewer samples needed when the metric is continuous rather than binary).
- Stratification uses weighted score trajectory slope, not binary pass rate slope, for tier classification — a project improving from 0.3 to 0.5 on weighted score is `active` even if it still fails the binary gate every time.
- Anomaly detection on weighted scores produces more meaningful z-scores because the underlying distribution is approximately normal (continuous metric, not Bernoulli).

### 3.3 Per-Project Trajectory Analysis

```swift
public struct ProjectTrajectory: Sendable, Codable, Equatable {
    public let projectID: String
    public let direction: TrajectoryDirection
    public let slope: Double
    public let r2: Double
    public let windowScores: [WeightedGateScore]
    public let inflectionDate: Date?
    public let inflectionType: InflectionType?
    public let confidence: StatisticalValidity
}

public enum TrajectoryDirection: String, Sendable, Codable {
    case improving
    case stable
    case degrading
    case insufficient
}

public enum InflectionType: String, Sendable, Codable {
    case recovery
    case regression
}
```

**Computation:**
- Ordinary least squares regression on `weightedScore` over time (daily snapshots).
- `direction` is classified by slope magnitude relative to score range:
  - `|slope| < 0.005` per day → `stable`
  - `slope > 0.005` → `improving`
  - `slope < -0.005` → `degrading`
  - `< 3 data points` → `insufficient`
- `inflectionDate`: the most recent date where the 3-day moving average changes direction (positive slope → negative or vice versa). Detects "was improving, now regressing" without requiring the full trajectory to be negative.
- `r2`: goodness of fit. Low r² with a clear slope means high variance (oscillating project). High r² with near-zero slope means genuinely stable.
- `confidence`: derived from the number of data points in the trajectory, using the same `StatisticalValidity` thresholds (insufficient < 3, preliminary 3–29, valid ≥ 30).

**Interaction with other components:**
- Trajectory direction feeds back into tier classification: a project with `direction: .improving` is classified as `active` even if its absolute pass rate is low.
- Trajectory data is the primary input for the narrative's "project health highlights" section — instead of manually reading snapshot arrays, the narrative generator can sort projects by slope and report the top improvers and degraders.
- Inflection detection feeds anomaly alerting: a project that was `improving` and inflects to `degrading` generates an anomaly even if its absolute score is still above the baseline mean. This catches regressions early, before they show up in the aggregate portfolio metric.

### 3.4 Validity-Gated Anomaly Decisions

```swift
public struct GatedAnomaly: Sendable, Codable, Equatable {
    public let anomaly: StatisticalAnomaly
    public let gatedSeverity: GatedSeverity
    public let actionability: Actionability
}

public enum GatedSeverity: String, Sendable, Codable {
    /// Baseline is valid (n≥30). z-score is trustworthy. Act on it.
    case confirmed
    /// Baseline is preliminary (3≤n<30). z-score is directional. Investigate.
    case directional
    /// Baseline is insufficient (n<3). z-score is unreliable. Ignore.
    case unreliable
}

public enum Actionability: String, Sendable, Codable {
    /// Anomaly requires investigation (confirmed + extreme/significant).
    case investigate
    /// Anomaly is worth noting but not urgent (confirmed + notable, or directional + extreme).
    case monitor
    /// Anomaly exists but the baseline can't support conclusions.
    case defer_
    /// Anomaly is explained by a known event (e.g., triage batch).
    case explained
}
```

**Decision matrix:**

| Baseline Validity | Raw Severity | Gated Severity | Actionability |
|---|---|---|---|
| valid (n≥30) | extreme | confirmed | investigate |
| valid (n≥30) | significant | confirmed | investigate |
| valid (n≥30) | notable | confirmed | monitor |
| preliminary (3–29) | extreme | directional | monitor |
| preliminary (3–29) | significant | directional | monitor |
| preliminary (3–29) | notable | directional | defer_ |
| insufficient (<3) | any | unreliable | defer_ |

The `explained` actionability is set by the refiner when it detects that an anomaly coincides with a known event — specifically, when the override rate anomaly occurs on the same date as a calibration batch (>100 calibrations in a single day). This prevents the triage event from generating persistent "investigate" alerts.

**Interaction with other components:**
- Anomaly detection switches from corpus-wide baselines to active-tier baselines. Because `active` projects have more consistent behavior than the full portfolio, the baseline standard deviation is smaller, which means genuine anomalies produce higher z-scores and are detected earlier — while noise from `baseline`/`firstContact` projects no longer inflates the variance.
- The `GatedSeverity` determines how the anomaly is rendered in the dashboard and narrative. `confirmed` anomalies get highlighted; `directional` anomalies get a footnote; `unreliable` anomalies are suppressed from the narrative entirely.
- As the corpus accumulates daily snapshots, baselines transition from `preliminary` to `valid`, and `directional` anomalies automatically upgrade to `confirmed` — no code change or manual intervention required. The system becomes more confident over time without any parameter tuning.

---

## 4. Interaction Model

The four components form a feedback loop:

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   Stratification ──→ determines which projects feed ──→      │
│        │              the baseline                           │
│        │                                                     │
│        ▼                                                     │
│   Severity Weighting ──→ replaces binary pass/fail ──→       │
│        │                  in all downstream metrics          │
│        │                                                     │
│        ▼                                                     │
│   Trajectory Analysis ──→ uses weighted scores for ──→       │
│        │                   slope computation                 │
│        │                   feeds back into tier               │
│        │                   classification                    │
│        ▼                                                     │
│   Anomaly Gating ──→ uses active-tier baselines ──→          │
│                       gates on validity before               │
│                       escalating                             │
│                                                              │
│   All four feed into: StratifiedStatistics on the pulse      │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**Concrete example of the interaction:**

Today's pulse with the current system:
- Portfolio pass rate: 19.7% → alarming-looking number
- Anomaly: overrideRate z=+3.36, severity=extreme → sounds urgent
- BusinessMath health: 19% → looks bad despite just achieving 0/0

Same data with the proposed system:
- Active portfolio weighted score: ~0.72 (4 active projects, most passing high-weight checkers)
- Baseline portfolio weighted score: ~0.35 (30+ projects, never remediated)
- Anomaly: overrideRate z=+3.36, gatedSeverity=directional (n=15), actionability=explained (triage batch)
- BusinessMath trajectory: improving (slope=+0.04/day), inflection at June 2 (recovery), confidence=preliminary

The second set of numbers tells you what's actually happening. The first set doesn't.

---

## 5. Constraints & Compliance

**Concurrency:** All new types are `Sendable` value types (structs and enums). No mutable state. Computation happens inside `PulseRefiner` (already an actor).

**Codable:** All types conform to `Codable` for JSON serialization in pulse output. Enum raw values are strings for human-readable JSON.

**Backward Compatibility:** `PulseStatistics` gains an optional `stratifiedStatistics: StratifiedStatistics?` field. Existing pulse JSON without this field will decode as `nil`. `StatisticalAnomaly` gains an optional `gatedSeverity: GatedSeverity?` field. `InstitutionalPulse.weekLabel` is renamed to `label` in code but uses `CodingKeys` to decode from either `"label"` or `"weekLabel"` in JSON, so existing pulse files load without migration. No existing fields are removed.

**Determinism:** All computations are deterministic from snapshot data. No randomness, no external state. Same snapshots → same stratification, scores, trajectories, and gated anomalies.

---

## 6. Dependencies

**Internal Dependencies:**
- `IJSSensor/TrendAnalysis.swift` — reuses `StatisticalValidity` enum
- `IJSSensor/StatisticalAnomaly.swift` — extends with gated severity
- `IJSSensor/DailySnapshot.swift` — input for trajectory computation
- `IJSRefiner/PulseRefiner.swift` — computation site
- `BusinessMath` — OLS regression for trajectory slope (already a dependency)

**External Dependencies:** None new.

---

## 7. Test Strategy

**Test Categories:**

| Category | What | Example |
|---|---|---|
| Stratification correctness | Tier assignment from snapshot data | 5 runs, improving slope → `active`; 5 runs, flat at 0% → `baseline`; 1 run → `firstContact` |
| Stratification edge cases | Boundary conditions for tier transitions | Exactly 3 runs; slope of exactly 0.005; pass rate improvement of exactly 10pp |
| Weight table completeness | Every checker ID in the codebase has a weight | Enumerate all checker IDs from QualityGateCLI, verify `defaultWeight(for:)` returns non-nil |
| Weighted score correctness | Score formula against known inputs | 10 checkers, 2 failing (safety=1.0, doc=0.2), total weight 6.0 → score 0.8 |
| Weighted score edge cases | All pass, all fail, single checker | All pass → 1.0; all fail → 0.0; single checker pass → 1.0 |
| Trajectory regression | OLS slope from known data points | Linear increasing scores → positive slope; constant scores → zero slope |
| Trajectory inflection | Inflection detection on synthetic data | V-shaped scores → inflection at trough; monotone → no inflection |
| Trajectory confidence | Validity from sample size | 2 points → insufficient; 15 points → preliminary; 35 points → valid |
| Anomaly gating matrix | Every cell of the decision matrix | valid + extreme → confirmed/investigate; preliminary + notable → directional/defer_ |
| Anomaly explanation | Triage batch detection | >100 calibrations on anomaly date → explained |
| Integration | Full pulse with stratification | Build a synthetic corpus with active + baseline + firstContact projects, verify StratifiedStatistics |

**Reference Truth:**
- OLS regression: validated against `BusinessMath.linearRegression()` (already tested with 5,731 tests)
- Weighted scoring: hand-computed from weight table (deterministic arithmetic)
- Decision matrix: exhaustive enumeration (finite cells)

**Validation Trace:**
- Stratification: Given projects A (10 runs, slope +0.02), B (10 runs, slope 0.0, pass rate 15%), C (1 run), D (0 runs) → A=active, B=baseline, C=firstContact, D=dormant
- Weighted score: Given checkers [safety:1.0, concurrency:1.0, test-quality:0.8, logging:0.5, doc-coverage:0.2], failing=[doc-coverage] → score = 1.0 - 0.2/3.5 = 0.943
- Trajectory: Given daily weighted scores [0.5, 0.55, 0.6, 0.65, 0.7] over 5 days → slope = 0.05/day, direction = improving, r² ≈ 1.0
- Gated anomaly: Given baseline validity=preliminary, raw severity=extreme → gatedSeverity=directional, actionability=monitor

---

## 8. Source & API Compatibility

**Breaking changes:** None. All additions are new optional fields on existing types or new types.

**Pulse JSON evolution:**
- Existing pulse JSON files (W19, W22, W23) will decode without `stratifiedStatistics` — it's optional.
- New pulse JSON files will include `stratifiedStatistics` when the refiner supports it.
- Dashboard renderers gracefully degrade: if `stratifiedStatistics` is nil, render the existing flat view.

---

## 9. Adversarial Review

**"The tier classification is arbitrary."** The thresholds (≥3 runs, 10pp improvement, slope ±0.005, 21-day tickle, 30-day dormancy) are initial values derived from the current corpus's distribution. They should be treated as configuration, not constants. However, the tier *concept* is not arbitrary — the distinction between "actively maintained," "at risk of going stale," and "never remediated" is real and observable. If the thresholds are wrong, the tiers will be wrong in predictable ways (too many projects classified as `active`, or too few), and the thresholds can be adjusted without changing the architecture.

**"Severity weights are subjective."** Yes. Any weighting scheme is a value judgment. The proposed weights encode the institutional position that safety > correctness > observability > documentation. This is defensible but debatable. The weights are centralized in `SeverityWeight.defaults` so they can be reviewed and updated as a policy decision, not scattered across the codebase. The alternative — no weighting, binary pass/fail — is also a value judgment: it says all checkers are equally important, which is demonstrably wrong.

**"This adds complexity to the pulse without proven benefit."** The current pulse produces numbers that require manual narrative interpretation to be useful (as demonstrated by the W23 narrative needing to explain why 19.7% isn't alarming). The proposed system produces numbers that mean what they say. The complexity cost is real (~400 lines of new code, 4 new types), but it's concentrated in the model and refiner layers — the dashboard renderers just display different numbers in the same format. The alternative is to keep writing narratives that explain away misleading metrics.

**"Trajectory analysis with n<30 is unreliable."** Correct, which is why trajectories carry their own `confidence: StatisticalValidity` field. A trajectory with `confidence: .insufficient` (< 3 points) gets `direction: .insufficient` and is not used for tier classification. The system explicitly models its own uncertainty rather than pretending it doesn't exist.

---

## 10. Alternatives Considered

**Manual project tagging instead of automatic stratification.** Rejected because it requires ongoing maintenance — every new project needs to be tagged, tags need to be updated as projects transition between states, and stale tags produce worse results than no tags. Automatic classification from snapshot data is always current.

**Configurable per-project severity weights.** Considered and deferred. Per-project weights add a combinatorial explosion of configuration states. The institutional weights represent a portfolio-wide value system; if a project disagrees with a weight, the correct response is to fix the checker or add an override, not to adjust the weight. Per-project weights could be added later as a `severity-overrides.yml` config without changing the architecture.

**Bayesian anomaly detection instead of z-score gating.** A Bayesian approach (e.g., conjugate priors on the pass rate) would naturally incorporate sample size uncertainty. Rejected for now because the current z-score machinery is already built and tested; the gating mechanism achieves the same practical outcome (don't trust small samples) with less implementation complexity. If the corpus reaches >100 daily samples and the gating still feels too coarse, Bayesian methods would be the natural next step.

**Composite health index (single number per project).** Considered combining weighted score, trajectory, and anomaly status into a single "health index." Rejected because a composite index obscures the components that inform action. A project with weighted score 0.9 but degrading trajectory needs different action than one with score 0.5 but improving trajectory. Keeping the components separate lets the narrative and dashboard present the relevant dimension for each project.

---

## 11. Daily Pulse and Narrative Cadence

Pulse generation moves from weekly to daily. This has cascading benefits across the system:

**Baseline maturity acceleration.** At daily cadence, the corpus accumulates one snapshot per active project per day. The n≥30 threshold for `valid` baselines is reached in ~30 days instead of ~30 weeks. By mid-July 2026, the active-tier baseline will be `valid` and anomaly detection will be fully trustworthy.

**Regression detection latency.** A regression introduced on Monday surfaces in Tuesday's pulse, not the following week's narrative. Combined with trajectory inflection detection, this means a project that was `improving` and starts `degrading` generates a signal within 24–48 hours.

**Tier classification freshness.** The 30-day classification lookback window slides daily. A project that stops gating passes through `atRisk` at day 21 and transitions to `dormant` at day 30, with daily digest tickle alerts in between.

### Dual-cadence narrative model

| Cadence | Name | Content | Generation |
|---|---|---|---|
| Daily | Daily Digest | Tier changes, trajectory inflections, new anomalies, active-tier weighted score | Template-driven from `StratifiedStatistics` — no LLM required |
| Weekly | Weekly Narrative | Deep analysis, cross-project patterns, forward guidance, context interpretation | LLM-generated (claude-opus or claude-sonnet) from the week's daily digests + pulse JSON |

**Daily Digest format** (generated by `PulseRefiner`, written alongside the pulse JSON):

```markdown
## Daily Digest — 2026-06-05

Active portfolio: 0.72 weighted score (4 projects)
Baseline portfolio: 0.35 weighted score (31 projects)

**Tier changes:** None
**At-risk tickle:** SwiftSVG last gated 24 days ago — goes dormant in 6 days
**Trajectory inflections:** BusinessMath: recovery inflection on June 2 (slope +0.04/day)
**New anomalies:** None (1 directional/explained: override rate z=+3.36, triage batch)
**Gate runs today:** 12 across 8 projects (10 passed, 2 failed)
```

The daily digest is pure computation — no judgment, no interpretation, no LLM. It's a structured report that a human or an LLM can consume. The weekly narrative adds the "so what" layer: why trajectory X matters, what to do about anomaly Y, which project to prioritize next.

### Pulse file structure

```
pulse/
  2026-06-05/
    PULSE_2026-06-05.json          # Full pulse with stratifiedStatistics
    DIGEST_2026-06-05.md           # Template-generated daily digest
  2026-W23/
    NARRATIVE_2026-W23.md          # LLM-generated weekly narrative
    PULSE_2026-W23.json            # Weekly aggregate pulse (union of daily pulses)
```

Daily pulse files use ISO date labels (`2026-06-05`). Weekly narratives continue using ISO week labels (`2026-W23`). The weekly pulse is an aggregation of the week's daily pulses, not a separate generation — this avoids drift between daily and weekly views.

---

## 12. Resolved Design Decisions

### Dormant project definition and tickle

A **dormant** project is one that has telemetry in the corpus (historical gate runs exist) but zero gate runs in the trailing 30-day classification window.

- Dormant projects appear in the pulse inventory (the `projects` array) but are excluded from all statistical computation: they don't feed baselines, don't generate anomalies, don't count toward portfolio metrics.
- The 30-day classification window is independent of the pulse generation cadence. The pulse runs daily, but looks back 30 days to classify tiers. This gives projects that gate on push (not on schedule) a full month of inactivity before they're classified as dormant.
- A project transitions from `dormant` back to `active`/`baseline`/`firstContact` as soon as a new gate run appears in the 30-day window. No manual intervention required.

**Tickle (at-risk warning):** Before a project goes dormant, it passes through `atRisk` — a 9-day transitional state triggered when the most recent gate run is 21+ days old. At-risk projects still participate in statistical computation (their data is recent enough to be useful), but the daily digest flags them with a countdown: "ProjectX last gated 23 days ago — goes dormant in 7 days." This gives the owner a clear window to either re-gate the project or consciously let it go dormant. The tickle requires no configuration and no response — dormancy is the natural default for projects that aren't being actively worked on.

### Baseline scope

Active-tier projects feed a **cross-active corpus baseline** for corpus-level anomaly detection. Per-project trajectories handle individual project signals. This is the natural resolution once dormant and firstContact projects are excluded: the active tier is a coherent population with similar engagement characteristics, making the pooled baseline meaningful. Per-project baselines would require n≥30 *per project*, which at daily cadence takes a month per project — the cross-active baseline reaches n≥30 in ~30 days regardless of how many projects are active.

---

## 13. Institutional Learning Loop

The pulse surfaces issues. The quality gate enforces rules. But neither mechanism currently closes the loop: when a systemic issue is detected, diagnosed, and resolved, the system doesn't mechanically learn from the resolution to prevent recurrence or accelerate remediation of the same pattern elsewhere.

This section defines how the pulse, quality gate, and CLAUDE.md workflow integrate into a closed feedback loop.

### The current gap

Today's workflow:

```
checker flags violation → calibration entry created → pulse clusters it →
narrative recommends action → human reads narrative → Claude session remediates →
next pulse confirms resolution → ... nothing feeds back to the checker or workflow
```

The gap is between "resolution confirmed" and "system improves." When we eliminated 253 weak-assertion instances in BusinessMath, the knowledge of *how* we did it (the three fix patterns: `try #require`, `.isFinite`, `contains`) and *why* it worked (5,731 tests still pass, quality gate 0/0) exists only in the session summary and the git history. The next time we remediate weak-assertion in another project, we start from scratch.

### Closing the loop: three mechanisms

#### 13.1 Remediation Playbooks (cluster → reusable pattern)

When a violation cluster is resolved in one project, the resolution is captured as a structured playbook:

```swift
public struct RemediationPlaybook: Sendable, Codable, Equatable {
    public let ruleId: String
    public let patterns: [RemediationPattern]
    public let validatedIn: [String]  // project IDs where this was applied
    public let testImpact: TestImpact
    public let createdFrom: String  // session summary reference
}

public struct RemediationPattern: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    public let beforeExample: String
    public let afterExample: String
    public let applicabilityCondition: String
    public let frequency: Double  // what % of instances used this pattern
}

public struct TestImpact: Sendable, Codable, Equatable {
    public let testsBeforeRemediation: Int
    public let testsAfterRemediation: Int
    public let allPassed: Bool
    public let gateResult: String  // "0 errors, 0 warnings"
}
```

**Example:** The weak-assertion remediation produces a playbook with three patterns:
1. `try #require(x)` — when value is force-unwrapped afterward (60% of instances)
2. `x?.isFinite == true` — standalone numeric existence check (30%)
3. `try #require(collection.first { pred })` — collection search with value binding (10%)

Validated in: BusinessMath. Test impact: 5,731 → 5,731, all pass, gate 0/0.

When the daily digest flags weak-assertion in another project (e.g., IconquerAI with 103 runs and test-quality as the top failing checker), the playbook is available as a starting point. The Claude session can load the playbook instead of re-discovering the fix patterns.

**Storage:** `<corpus>/playbooks/<ruleId>.json`. Written by the session that completes the remediation (as part of the session summary step in CLAUDE.md workflow). Read by future sessions via the quality gate CLI or directly.

**CLAUDE.md integration:** The existing rule "When fixing warnings, generate/update CHANGELOG.md, README.md, and a session summary as part of the same commit" extends to: "When resolving a violation cluster to zero in a project, generate a remediation playbook if one doesn't exist for that rule, or update the existing one with the new project as a validation point."

#### 13.2 Checker Calibration Feedback (calibration distribution → rule refinement)

The calibration triage revealed that 54.7% of overrides are `design-constraint` — the rule is correct in general but wrong in this specific context. When a rule's design-constraint rate exceeds a threshold (e.g., >60% of its overrides are design-constraint), that's a signal that the rule needs refinement: better exemption patterns, narrower scope, or a precision filter.

The daily digest surfaces this as a **rule health metric**:

```markdown
**Rule health:**
  security.path-traversal: 64% design-constraint (540/835) — consider precision filter
  logging.silent-try: 63% design-constraint (596/942) — consider exemption pattern
  weak-assertion: 17% design-constraint (1,200/7,022) — rule is well-calibrated
```

This directly connects to the existing PrecisionFilters-Batch proposal and the checker's own `overrideIfExempted()` mechanism. When the pulse shows a rule's design-constraint rate is high, the action is to write a precision filter or exemption pattern — not to suppress the rule, but to teach it to skip the cases it's already known to be wrong about.

**Mechanical linkage:** The pulse computes `designConstraintRate = designConstraintCount / totalOverrides` per rule. When this exceeds a configurable threshold (default 0.6), the daily digest includes it in the rule health section. The weekly narrative recommends specific precision filter or exemption pattern work. This feeds into the existing design proposal pipeline (e.g., `PrecisionFilters-Batch.md`).

#### 13.3 Forward Guidance Tracking (narrative recommendations → structured backlog)

The current forward guidance is prose in the narrative. Once written, there's no mechanism to track whether it was addressed. The W23 narrative had 4 forward guidance items; we manually struck them through in the provisional narrative. This doesn't scale.

Forward guidance becomes structured data on the pulse:

```swift
public struct ForwardGuidance: Sendable, Codable, Equatable {
    public let id: String  // stable identifier, e.g., "W23-1"
    public let created: Date
    public let description: String
    public let status: GuidanceStatus
    public let resolvedDate: Date?
    public let resolvedBy: String?  // session summary reference
}

public enum GuidanceStatus: String, Sendable, Codable {
    case open
    case inProgress
    case resolved
    case superseded
}
```

**Lifecycle:**
1. The weekly narrative creates forward guidance items (status: `open`)
2. The daily digest shows open items as a persistent checklist
3. When a session resolves an item, it updates the status to `resolved` with a reference to the session summary
4. The next weekly narrative acknowledges resolutions and creates new items

**Storage:** `<corpus>/guidance/` directory, one JSON file per guidance item. The pulse aggregates all open items into its `forwardGuidance` array.

**CLAUDE.md integration:** Session start checks for open forward guidance items relevant to the current project. The `/recover` skill includes forward guidance status in its context restoration. This means a new session on BusinessMath would see: "Open guidance: weak-assertion portfolio rollout (7,022 instances across 27 projects)" — providing immediate context for what work is pending.

### How the loop connects to CLAUDE.md

The CLAUDE.md workflow already mandates:
- Run quality gate before committing (catches violations)
- Resolve all errors and warnings to 0/0 (forces remediation)
- Generate session summary (captures what was done)

The learning loop adds three outputs to the session summary step:
1. **Playbook update** — if a violation cluster was resolved, capture the patterns
2. **Guidance update** — if a forward guidance item was addressed, mark it resolved
3. **Rule health note** — if the remediation revealed a high design-constraint rate, flag it for precision filter work

These three additions are lightweight — they're metadata attached to the session summary, not separate workflows. They ensure that every remediation session leaves the system slightly smarter than it found it.

---

## 14. Future Directions

- **Checker-level trend analysis.** Track the weighted score contribution of each checker over time. Detect when a specific checker starts failing more frequently across the portfolio (rule regression) vs. a specific project (project regression).
- **Predictive trajectory.** Use trajectory slope to forecast when a project will reach a target weighted score. "At current rate, BusinessMath reaches 0.95 in ~5 days."
- **Severity weight calibration from outcomes.** Track which checker failures lead to actual bugs/incidents. Adjust weights based on empirical impact, not a priori judgment.
- **Automated weekly narrative generation.** As the daily digest accumulates structured data, the weekly narrative could be generated from a formalized prompt template rather than ad-hoc conversation sessions. The daily digests provide the structured input; the LLM provides the interpretive layer.
- **Playbook-driven batch remediation.** Once playbooks exist for the top violation clusters, a Claude session could apply a playbook across multiple projects in parallel (same pattern as the BusinessMath weak-assertion batch), using the playbook's patterns as the fix strategy rather than re-discovering them each time.

---

## 15. Documentation Strategy

**Documentation Type:** Narrative Article Required

**Complexity Threshold Check:**
- Does it combine 3+ APIs? Yes (4 interacting subsystems)
- Does explanation require 50+ lines? Yes
- Does it need theory/background context? Yes (z-scores, OLS, confidence intervals)

**Article Name:** PulseStatisticalMaturityGuide.md
