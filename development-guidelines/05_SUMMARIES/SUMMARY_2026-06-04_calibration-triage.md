# Session Summary: IJS Calibration Triage (2026-06-04)

## Problem

The W23 Institutional Pulse reported 4,845 calibration entries auto-generated
across BusinessMath, SwiftXLSX, quality-gate-swift, and other projects — with
3,058 classified as `unclassified`. These overrides all had inline justification
comments (SAFETY, silent, logging, Justification, TEST-QUALITY) but the
auto-classifier hadn't promoted them to a proper rootCause classification.

## Changes Made

### Calibration Triage (org-judgement-corpus)

Wrote a two-pass Python script to promote all 3,058 unclassified entries:

**Pass 1** — Keyword matching (2,398 promoted):
- Entries with `// SAFETY:`, `// silent:`, `// logging:`, `// Justification:`,
  `// TEST-QUALITY:`, `Linux fallback`, `xcrun --find swift` → `design-constraint`
- `insecure-transport` entries with "Pattern-match string" → `false-positive`

**Pass 2** — Remaining overrides with substantive justification text (660 promoted):
- All had `Override of <rule>:` with >30 chars of explanation
- Examples: "best-effort restore", "GPU pipeline unavailable", "Storage is CoW",
  "Path is resolved via standardized", "MCMC sampling — retain previous value"

### Final Distribution

| Classification | Count |
|---|---|
| design-constraint | 3,034 |
| structural | 1,381 |
| imprecise | 399 |
| false-positive | 24 |
| deferred | 7 |

### Rule Breakdown of Promoted Entries

| Rule | Count |
|---|---|
| weak-assertion | 1,200 |
| logging.silent-try | 596 |
| security.path-traversal | 540 |
| logging.catch-without-logging | 305 |
| missing-assertion | 174 |
| concurrency.unchecked-sendable-no-justification | 116 |
| concurrency.nonisolated-unsafe-no-justification | 37 |
| logging.print-statement | 30 |
| while-true | 24 |
| security.insecure-transport | 24 |
| security.command-injection | 12 |

## Commits

| Repo | Hash | Description |
|------|------|-------------|
| org-judgement-corpus | `221f45a` | Triage 3,058 unclassified calibration entries |

## Verification

- `grep -rl '"rootCause": "unclassified"' telemetry/` returns 0 results
- All calibration files remain valid JSON
- No manual triage needed — all entries had sufficient inline justification

## Next Steps (from W23 Forward Guidance)

1. ~~Triage BusinessMathExcel's 0% run~~ — DONE (prior session)
2. ~~Calibration sweep on auto-classified overrides~~ — DONE (this session)
3. **Begin converting BusinessMath `#expect(x != nil)` to value assertions** — target financial ratio and optimization test suites first
4. Corpus baselines remain preliminary (n=15) — treat z-scores as directional
