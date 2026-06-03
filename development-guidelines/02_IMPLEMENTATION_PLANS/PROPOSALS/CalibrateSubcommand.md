# Proposal: Auto-Calibration + `quality-gate calibrate` Subcommand

## Problem

The IJS feedback loop — override → calibrate → refine → discover patterns — is broken at
the calibration step. The corpus has zero calibrations after 86+ gate runs because recording
one requires hand-authoring `JudgmentCalibration` JSON with `RootCauseAnalysis`,
`chainOfInquiry`, and `FiveStepStage` fields. Nobody does that.

Meanwhile, every gate run already sees the overrides: `// SAFETY:` comments, `// silent:`
comments, `// Justification:` comments. Each one has a rule ID, a file path, a line number,
and justification text. The information needed to classify these exists — the gate just
discards it.

The W22 pulse narrative flagged this: baselines are still "preliminary" and no calibrations
exist. As checkers approach statistical validity (≥ 30 samples), uncalibrated thresholds risk
locking in rules that don't match reality. The pulse can tell you "safety.force-unwrap was
overridden 12 times" but can't tell you *why* — so it can't recommend tuning the checker.

## Solution

Two mechanisms, different cadences:

### 1. Auto-Calibration (every gate run)

When `quality-gate --check` processes overrides and writes telemetry, it also generates
`JudgmentCalibration` records from the `DiagnosticOverride` data already in the results.
Root cause is inferred from the justification text using pattern matching. This requires
**zero user action** — calibrations accumulate as a byproduct of running the gate.

### 2. `quality-gate calibrate` Subcommand (manual, periodic)

A CLI subcommand for reviewing auto-generated calibrations, reclassifying misidentified
root causes, recording calibrations that can't be auto-inferred, and viewing coverage stats.
This is the refinement tool, not the primary recording mechanism.

Together: the gate auto-generates calibrations at run time, the pulse aggregates them
weekly, and the `calibrate` command is for quarterly review when the pulse recommends
checker tuning.

## Part 1: Auto-Calibration

### Where It Plugs In

`QualityGateCLI.swift` lines 378-393 currently build `CheckResultMetadata` with hardcoded
empty arrays:

```swift
let metadata = CheckResultMetadata(
    ...
    overrides: [],        // ← DiagnosticOverrides exist in allResults but aren't extracted
    ...
)
...
try await writer.write(metadata: metadata, calibrations: [], to: corpus)  // ← always empty
```

The fix: extract `DiagnosticOverride` records from `allResults`, convert each to an
`OverrideRecord` and a `JudgmentCalibration`, and pass them through.

### Root Cause Classification

The justification text already implies the root cause in most cases. Classification uses
keyword/phrase matching against the comment content:

| Pattern in justification text | Inferred root cause | Example |
|-------------------------------|--------------------|---------| 
| "constant", "hardcoded", "literal", "validated by", "guaranteed", "can't fail" | `false-positive` | `// silent: constant regex pattern` |
| "CLI", "user-facing", "expected here", "by design", "required by", "protocol" | `design-constraint` | `// SAFETY: CLI tool creates local directory` |
| "path traversal", "reject", "validated", "bounds check" | `false-positive` | `// SAFETY: reject path traversal` |
| "TODO", "tracked in", "will fix", "temporary", "workaround" | `deferred` | `// silent: will fix in #123` |
| "external", "third-party", "upstream", "dependency" | `third-party` | `// SAFETY: upstream API requires force cast` |
| "accept", "acknowledged", "risk is", "tradeoff" | `acceptable-risk` | `// Justification: accepted perf tradeoff` |
| (no match) | `unclassified` | Falls through — manual review needed |

The classifier is a pure function: `(String) -> RootCause`. It lives in a new file
`Sources/IJSAggregator/CalibrationClassifier.swift` so it's testable independently of
the CLI.

### Deduplication

The same override (same rule ID + same file + same justification text) will appear in every
gate run. Auto-calibration should not produce duplicate calibrations. The writer checks
existing calibrations for the current day and skips duplicates by (ruleId, filePath,
justification) tuple.

### What Changes in the Gate Run

```swift
// Extract overrides from all checker results
let allOverrides: [DiagnosticOverride] = allResults.flatMap { $0.overrides }
let overrideRecords = allOverrides.map { override in
    OverrideRecord(
        diagnosticOverride: override,
        author: "auto",
        riskTier: riskTier,
        authorityLevel: riskTier.requiredAuthority
    )
}

// Auto-generate calibrations from overrides
let classifier = CalibrationClassifier()
let calibrations = classifier.calibrate(overrides: allOverrides, projectID: projectID)

let metadata = CheckResultMetadata(
    ...
    overrides: overrideRecords,   // ← populated from actual results
    ...
)
try await writer.write(metadata: metadata, calibrations: calibrations, to: corpus)
```

### CalibrationClassifier

New file: `Sources/IJSAggregator/CalibrationClassifier.swift`

```swift
public struct CalibrationClassifier: Sendable {

    public enum InferredRootCause: String, Sendable {
        case falsePositive = "false-positive"
        case designConstraint = "design-constraint"
        case deferred
        case thirdParty = "third-party"
        case acceptableRisk = "acceptable-risk"
        case unclassified
    }

    /// Classify a justification comment into a root cause.
    public func classify(_ justification: String) -> InferredRootCause

    /// Generate calibrations from a set of diagnostic overrides.
    public func calibrate(
        overrides: [DiagnosticOverride],
        projectID: String
    ) -> [JudgmentCalibration]
}
```

## Part 2: Pulse Aggregation

The pulse refiner already reads calibrations via `TelemetryWriter.readCalibrations()` and
aggregates `rootCauseCounts` and `failedStepCounts`. Once auto-calibrations start flowing,
this works with no changes.

What the pulse narrative gains:

```
Override Analysis (W23):
  safety.force-unwrap: 12 overrides — 9 false-positive, 2 design-constraint, 1 deferred
    → False positive rate: 75%. Consider adding guard-chain recognition.
  concurrency.unchecked-sendable: 5 overrides — all design-constraint at tier 1
    → Stable pattern. Consider permanent exemption.
  logging.silent-try: 8 overrides — 6 deferred
    → Growing deferred backlog (4 unresolved since W20).
```

The narrative synthesizer (in org-judgement-system) already receives calibration summaries
in the `NarrativeContext`. Once calibrations exist, the LLM will naturally incorporate the
root cause distributions — no prompt changes needed.

## Part 3: `quality-gate calibrate` Subcommand

The manual tool for periodic review. Three modes:

### `quality-gate calibrate --status`

Shows override/calibration coverage and flags `unclassified` calibrations that need manual
review.

```
Calibration Status (quality-gate-swift)
  Window: 30 days

  Rule                         Overrides  Calibrated  Unclassified
  ──────────────────────────────────────────────────────────────────
  safety.force-unwrap              12         12          1
  concurrency.unchecked             5          5          0
  logging.silent-try                8          8          2
  
  Total: 25 overrides, 25 calibrated, 3 need manual review
```

### `quality-gate calibrate --coverage`

Shows per-checker sample counts against the statistical validity threshold.

```
Checker             Samples  Validity      Calibrations  FP Rate
─────────────────────────────────────────────────────────────────
safety               31     valid          12            75%
concurrency          28     preliminary     5             0%
doc-coverage         31     valid           0             —
logging              22     preliminary     8            12%

Checkers at validity: 2 of 4 (safety FP rate suggests checker tuning)
```

### `quality-gate calibrate --reclassify`

Reclassify a specific override's auto-generated calibration:

```bash
quality-gate calibrate --reclassify \
  --rule-id safety.force-unwrap \
  --file Sources/Foo.swift --line 42 \
  --root-cause acceptable-risk \
  --rationale "Pointer lifetime is bounded by the enclosing scope"
```

This writes a new calibration that supersedes the auto-generated one for that
(ruleId, file, line) tuple.

## Consistency Checker Integration

New diagnostic:

**Rule ID**: `calibration-recommended`  
**Severity**: `note`  
**Trigger**: Any checker with ≥ 30 samples AND false positive rate > 50%  
**Message**: "Checker '{id}' has a {n}% false positive rate across {samples} runs.
Consider tuning the checker or adding exemption patterns."

This is more useful than just "you have no calibrations" — it tells you which checkers are
actually miscalibrated and by how much.

## Architecture

### New Files

| File | Target | Purpose |
|------|--------|---------|
| `Sources/IJSAggregator/CalibrationClassifier.swift` | IJSAggregator | Justification → root cause classification |
| `Sources/QualityGateCLI/Calibrate.swift` | QualityGateCLI | Subcommand: status, coverage, reclassify |
| `Tests/IJSAggregatorTests/CalibrationClassifierTests.swift` | IJSAggregatorTests | Classification accuracy tests |
| `Tests/QualityGateCLITests/CalibrateTests.swift` | QualityGateCLITests | Subcommand tests |

### Modified Files

| File | Change |
|------|--------|
| `Sources/QualityGateCLI/QualityGateCLI.swift` | Extract overrides, generate calibrations, pass to writer |
| `Sources/QualityGateCLI/QualityGateCLI.swift` | Add `Calibrate.self` to subcommands |
| `Sources/ConsistencyChecker/ConsistencyChecker.swift` | Add `calibration-recommended` diagnostic |

### Module Dependencies

No new SPM targets. `CalibrationClassifier` goes in the existing `IJSAggregator` target
(already depends on `IJSSensor` for `JudgmentCalibration`). The `Calibrate` subcommand
goes in `QualityGateCLI`.

### Source & API Compatibility

No breaking changes. The auto-calibration enriches existing telemetry writes. The
`calibrate` subcommand and `calibration-recommended` diagnostic are additive.

Retrofits cleanly to v2.0.0: no public API changes, no new SPM targets, no new
dependencies.

## Constraints

- **No Claude Code dependency.** Pure CLI. No MCP, no AI integration.
- **Append-only corpus writes.** Calibrations are new files, never modifying existing data.
- **Corpus sync is the launchd job's responsibility.** The gate writes to disk; the 2-hour
  sync commits and pushes.
- **Classification is best-effort.** `unclassified` is a valid root cause — the system
  degrades gracefully when the justification text doesn't match any pattern.
- **No interactive prompts.** All input via flags for scriptability.

## Test Strategy

**CalibrationClassifier:**
- Known justification patterns → correct root cause classification
- Ambiguous/empty text → `unclassified`
- Mixed patterns (contains both "constant" and "TODO") → first match wins
- Deduplication: same override twice → one calibration

**Auto-calibration integration:**
- Gate run with overrides → calibrations written alongside metadata
- Gate run without overrides → `calibrations: []` (no change from current)
- Verify `TelemetryWriter.readCalibrations()` returns auto-generated records
- Verify pulse generation incorporates auto-calibration data

**Calibrate subcommand:**
- `--status` with known corpus → correct counts and unclassified flags
- `--coverage` → correct sample counts and FP rates
- `--reclassify` → new calibration supersedes auto-generated one
- Missing corpus config → clear error message

**Consistency checker:**
- Checker at 30+ samples with >50% FP rate → `calibration-recommended` note
- Checker at 30+ samples with <50% FP rate → no diagnostic
- Checker below 30 samples → no diagnostic

## Implementation Order

1. `CalibrationClassifier` + tests (TDD: red/green/refactor)
2. Wire auto-calibration into `QualityGateCLI.swift` main gate run
3. Fix `overrides: []` to extract actual overrides from results
4. Integration test: gate run → calibrations in corpus
5. `Calibrate.swift` — `--status` mode
6. `Calibrate.swift` — `--coverage` mode
7. `Calibrate.swift` — `--reclassify` mode
8. `calibration-recommended` diagnostic in consistency checker
9. `make install` and verify against live corpus
10. Run pulse generation to confirm calibration data flows into narrative

## Adversarial Review

**Strongest case for a different approach:**
The classification heuristics will misclassify some justifications, and "unclassified" will
accumulate as noise. A simpler approach: don't classify at all. Just count overrides per rule
per checker and report the ratio. "safety.force-unwrap has 12 overrides across 31 runs" is
already useful — you don't need to know *why* to notice the checker is too noisy.

This is genuinely compelling for the first iteration. The counter: without root cause
classification, the pulse can't distinguish "noisy checker" (high false positives → tune it)
from "risky codebase" (high acceptable-risk → monitor it). Both produce high override counts
but demand opposite responses.

**Where this design is most likely wrong:**
The keyword-matching classifier will need ongoing maintenance as new justification patterns
emerge. It's a heuristic, not a parser. Mitigation: `unclassified` is visible in
`--status`, so drift is detectable. The classifier is a single pure function, easy to update.

**What an experienced critic would say:**
"You're auto-generating institutional judgment artifacts. Isn't the whole point of the IJS
that judgment should be deliberate?" Yes — but the alternative is zero calibrations forever.
Auto-classification with manual review is strictly better than the current state of nothing.
The `--reclassify` command exists precisely for when the auto-classification is wrong.

---

**Date:** 2026-06-03  
**Author:** Justin Purnell + Claude Opus 4.6  
**Supersedes:** P3b `ijs_record_calibration` MCP tool (for calibration recording only —
P3b's read-only query tools remain valid as a future proposal)
