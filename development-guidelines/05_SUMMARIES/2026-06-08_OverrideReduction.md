# Session Summary: Override Reduction & Checker Calibration

**Date:** 2026-06-07 / 2026-06-08
**Scope:** quality-gate-swift + 8 portfolio projects

## Problem

The dashboard showed 1,498 overrides across the portfolio. Investigation revealed three compounding issues:
1. Override counting was cumulative across all runs in the 30-day window (inflated by line-number drift)
2. SAFETY/SECURITY/Justification comments were creating override records (documentation counted as bypasses)
3. The `logging.silent-try` checker flagged idiomatic Swift patterns (existence checks, Codable, cleanup)

## Changes

### quality-gate-swift (checker infrastructure)

- **Build stamp system**: `make build` embeds git commit hash via `BuildStamp.swift`; `generate-pulse.sh` and `daily-audit.sh` detect stale binaries
- **Override counting fix**: Pulse now uses latest-run-per-project instead of cumulative dedup across all runs
- **Checker calibration**: SAFETY, SECURITY, Justification, and logging exemption comments suppress diagnostics without creating override records
- **Silent-try whitelist**: Added `checkResourceIsReachable`, `resourceValues(forKeys:`, `container.decode(`, `singleValueContainer()`, `removeItem(at`, `.close()` to defaults
- **False positive fixes**: `unseeded-random` now skips enum cases and `using:` calls; `hig.navigation-pattern` skips sheets/conditionals; `stochastic-collection-shuffle` skips `rng.shuffle(&collection)` inout pattern
- **Concurrency**: Replaced custom Mutex, DataBox, nonisolated(unsafe) with Synchronization.Mutex/Atomic; retroactive Sendable on IndexStoreDB
- **Logging**: Added os.Logger calls to all 48 silent catch blocks
- **CI**: Disabled automatic GitHub Actions triggers (daily audit + build/test now local via launchd)

### Portfolio projects

| Project | Changes |
|---|---|
| SwiftCLIKit | NSLock → Synchronization.Mutex/Atomic (14 overrides eliminated) |
| sicp-swift-companion | NSLock → Mutex, immutable-after-init → Sendable (12 eliminated, 6 accepted) |
| IconquerAI | Immutable-after-init → Sendable, Atomic, retroactive MLXArray Sendable + 15 force unwraps fixed |
| IconquerCLI | NSLock → Mutex/Atomic (11 eliminated) |
| SwiftMCPServer | Migrated swift-log → os.Logger |
| ApplesoftBASIC | Bumped to macOS 15, NSLock → Synchronization.Mutex |
| IconquerApp | Removed false-positive HIG override comments |
| IconquerCore | Removed false-positive unseeded-random override comments |

## Result

- **Portfolio overrides: 1,498 → 0** (across all 9 touched projects)
- **quality-gate-swift: 0 errors, 0 warnings, 0 overrides**
- All 9 projects pass quality gate clean
- Daily audit now runs locally via launchd (01:00), no CI minutes consumed
