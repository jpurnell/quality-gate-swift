# Session Summary — 2026-05-29

## Anti-Gaming Mitigants & Narrative Durability

### Context
A criticism document ("Managing Justification Debt and System Gaming in Institutional Judgment") identified five vectors for gaming the quality gate system. All five mitigants were designed, implemented with TDD, and shipped in a single session across two repos.

### Changes — quality-gate-swift

**M1: Justification Quality Enforcement** (`0d23e15`)
- New `JustificationValidator` in QualityGateCore — 8-word minimum, 13-phrase denylist, duplicate detection
- Integrated into `ConcurrencyAuditor.overrideIfJustified()` — emits `justification.too-short`, `justification.generic`, `justification.duplicate`
- 13 unit tests (JustificationValidatorTests) + 6 integration tests (JustificationQualityTests)

**M2: Scope-Aware reduceMotion Check** (`0d23e15`)
- `AccessibilityAuditor.hasReduceMotionCheck(for:)` walks syntax tree through `FunctionDeclSyntax`, `AccessorDeclSyntax`, `ClosureExprSyntax`
- Replaces line-radius heuristic that missed checks in different scopes
- 4 new tests verifying scope-aware behavior

**M3: QG_SKIP Accountability** (`0d23e15`)
- `QG_SKIP=1` is now rejected — requires issue URL (e.g. `QG_SKIP=https://github.com/org/repo/issues/42`)
- New `SkipRecord` struct in IJSSensor, persisted to corpus via `TelemetryWriter.writeSkip()`
- Skip events are traceable through the IJS corpus

**M5: Override-to-Resolution Ratio** (`0d23e15`)
- New `suppressionPattern` case in `ConsistencyMatchType` with 0.20 weight
- `PolicyDiscoveryAuditor.detectSuppressionPatterns()` computes `resolutionRate = fixes / (fixes + overrides)`
- Flags when rate < 0.5 with >= 2 overrides — detects "override instead of fix" pattern
- 6 test cases including boundary conditions and exemptions

**Other quality-gate-swift changes:**
- Hardcoded-date rule in TestQualityAuditor (nil-coalescing scope only) — `6cc0f5c`
- Pre-push hook runs `swift test` — `c0112b4`
- ConsistencyCheckerTests time-sensitive fix — `7459d83`

### Changes — org-judgement-system

**M4: Proposal Staleness Tracking** (`9d462a4`)
- `PulseRefiner.trackProposalStaleness()` tracks `proposalFirstSeen` per-proposal
- Generates `stale-proposal` ViolationClusters after 3+ weeks without resolution
- New `proposalFirstSeen: [String: String]?` on `InstitutionalPulse`

**Narrative Durability** (`d075115`)
- Root cause: CI's `--narrate` flag calls LLM, LLM fails, template fallback overwrites existing LLM narrative
- Fix: restructured `Refine.swift` with single narrative lifecycle
- Priority chain: new LLM > existing LLM > existing template > fresh template
- `loadExistingNarrative()` reads directly from the week's pulse JSON (not `readLatestPulse` which could return wrong week)
- `NarrativeSource` enum tracks provenance through the pipeline
- Markdown file only written on fresh LLM success

### Design Proposal
- `development-guidelines/02_IMPLEMENTATION_PLANS/PROPOSALS/AntiGamingMitigants.md`

### Test Summary
- quality-gate-swift: 1,491 tests, 192 suites — all passing
- org-judgement-system: 363 tests, 49 suites — all passing
- Quality gate: 0 errors, 0 warnings

### Key Debugging Notes
- `.generic(matchedPhrase:)` has an associated value — bare `==` comparison fails to compile, use `if case` binding
- `readLatestPulse(from:)` can return a different week than intended — read the specific week's JSON directly
- Pre-push hook `grep -q "failed"` matches test names like "Returns failed status" — use exit code instead
