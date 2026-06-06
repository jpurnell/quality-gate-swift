# Override Reduction Plan

## Problem

The quality gate corpus reports 10,234 overrides in the current 30-day window, triggering a z=3.30 anomaly. A single full-suite run of quality-gate-swift produces 389 overrides. With ~80 runs in the window across all projects, the total scales multiplicatively. The override signal is so noisy that genuine policy violations are invisible.

## Current Override Inventory (per single full-suite run of quality-gate-swift)

| Rule | Count | Type | Action |
|------|-------|------|--------|
| security.path-traversal | 108 | `// SAFETY:` inline | Config exemption |
| logging.silent-try | 99 | `// silent:` inline | Triage: fix or config |
| logging.print-statement | 93 | `// logging:` inline | Config exemption |
| logging.catch-without-logging | 44 | `// logging:` inline | Triage: fix or config |
| missing-assertion | 29 | test quality | Fix in tests |
| logging.no-os-logger-import | 6 | `// logging:` inline | Config exemption |
| concurrency.unchecked-sendable | 3 | `// Justification:` | Keep (correct usage) |
| while-true | 2 | event loops | Keep |
| security.command-injection | 2 | `// SAFETY:` inline | Config exemption |
| security.insecure-transport | 2 | `// SAFETY:` inline | Config exemption |
| concurrency.nonisolated-unsafe | 1 | `// Justification:` | Keep |
| **Total** | **389** | | |

## Reduction Strategy

### Phase 1: Fix Test Quality (eliminate ~29 overrides/run)

**Target:** `missing-assertion` and `weak-assertion` overrides in test files.

These are real test quality issues — tests that assert `!= nil` or `!= 0` instead of checking specific values. Fix the tests to use proper assertions.

**Scope:** ~3 weak-assertion instances + ~29 missing-assertion patterns in quality-gate-swift tests.

### Phase 2: Config-Level Exemptions (eliminate ~209 overrides/run)

**Target:** `security.path-traversal` (108), `logging.print-statement` (93), `logging.no-os-logger-import` (6), `security.command-injection` (2), `security.insecure-transport` (2).

These rules produce false positives in CLI tools that intentionally use `print()` for user output and `FileManager` for configured paths. Instead of per-line `// SAFETY:` and `// logging:` comments, add project-level exemptions in `.quality-gate.yml`:

```yaml
overrides:
  security.path-traversal:
    scope: Sources/
    reason: "CLI tool reads from configured corpus paths, not user input"
  logging.print-statement:
    scope: Sources/QualityGateCLI/
    reason: "CLI tool uses print() for user-facing output"
```

This requires implementing a `scope`-based override system in the OverrideProcessor. One override record per config entry replaces N inline comments.

### Phase 3: Triage Logging Overrides (reduce ~143 overrides/run)

**Target:** `logging.silent-try` (99), `logging.catch-without-logging` (44).

Triage each instance:
- **Truly silent:** Keep the `// silent:` comment — these are intentional (e.g., non-fatal reload, optional feature)
- **Should log:** Add `os.Logger` calls and remove the `// silent:` comment
- **Should propagate:** Convert `try?` to `try` with proper error handling

Estimate: ~30% fixable (reduce by ~43), ~70% keep as legitimate overrides.

### Phase 4: Pulse Deduplication (reduce reported total by ~90%)

**Target:** The 80-run × 389-override/run multiplier.

Add deduplication in `PulseRefiner.buildStatistics()`: instead of counting raw `meta.overrides.count` across all runs, count unique `(ruleId, filePath, line)` tuples. The same `// SAFETY:` comment appearing in 80 runs should count as 1 override, not 80.

This doesn't change the source code but dramatically reduces the reported number and makes the anomaly detection meaningful.

## Expected Impact

| Phase | Per-run reduction | Effort |
|-------|------------------|--------|
| Phase 1: Fix tests | -29 (389 → 360) | Small — fix ~30 test assertions |
| Phase 2: Config exemptions | -209 (360 → 151) | Medium — new config feature + remove inline comments |
| Phase 3: Triage logging | -43 est. (151 → 108) | Medium — audit ~143 sites |
| Phase 4: Pulse dedup | Report drops from 10,234 to ~400 unique | Small — refiner change |

After all phases: ~108 legitimate per-run overrides (concurrency justifications + genuine silent-try cases), and the pulse reports ~400 unique overrides instead of 10,234.

## Implementation Order

1. Phase 1 first (quick wins, real quality improvement)
2. Phase 4 next (biggest impact on the anomaly signal)
3. Phase 2 (requires new config feature)
4. Phase 3 (audit work)
