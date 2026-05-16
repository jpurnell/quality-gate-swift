# Session Summary: Complexity Analyzer — False Positive Reduction

**Date:** 2026-05-16
**Branch:** main
**Status:** Complete, quality-gate passes (22/22 checkers green with --strict)

## What Was Done

Completed the PatternDetector false-positive reduction system for the ComplexityAnalyzer module (Tier 2). The checker was producing ~80 noise diagnostics (mostly `String.contains` flagged as array membership) — reduced to 6 legitimate, actionable findings.

### Changes Made

**Sources/ComplexityAnalyzer/PatternDetector.swift** — Major rework:
- Added parameter type tracking (`extractParameterTypes` from function signatures)
- Changed detection logic from "flag unless Set/String" to "only flag confirmed Arrays"
- Added `isSubstringContains` — skips `.contains` with string literal arguments
- Added `isArrayReceiver` / `isArrayInitializer` for Array variable tracking
- Added `// complexity-ok:` suppression comment system (pre-scans trivia)
- Removed dead `isSetReceiver`/`isStringReceiver` (logic subsumed by Array-only approach)

**Sources/ComplexityAnalyzer/CognitiveComplexityVisitor.swift:**
- Both `FunctionDeclSyntax` and `InitializerDeclSyntax` visitors now pass parameter types to PatternDetector

**Sources/ComplexityAnalyzer/StdlibCostTable.swift:**
- Integrated `constantOperations` into `cost(for:)` (was defined but unused)

**Sources/ComplexityAnalyzer/ComplexityModels.swift:**
- Added `CaseIterable` to `EstimationConfidence` and `RecursionClassification`
- Added `isUncertain` computed property to `EstimationConfidence`
- Added `description` to `ComplexityBasis`
- Added `estimatedComplexity` to `RecursionClassification`
- (All to resolve unreachable-code findings for Tier 3 API surface)

**Tests/ComplexityAnalyzerTests/PatternDetectorTests.swift** — 4 new tests:
- String.contains not flagged as membership
- Locally declared Set variable recognized
- `// complexity-ok:` comment suppression (previous line)
- `// complexity-ok:` trailing comment suppression (same line)

**Tests/ComplexityAnalyzerTests/BigOEstimatorTests.swift** — 1 new test:
- Model types exercised (RecursionClassification, EstimationConfidence.low)

**Tests/IJSDashboardCoreTests/CorpusReaderPulseTests.swift:**
- Fixed 3 weak assertion warnings (`!= nil` → `try #require`)

### Results

- **Before:** 133 diagnostics, ~80 false positives from String.contains
- **After:** 51 diagnostics, 6 legitimate `contains-in-filter` findings
- **Test suite:** 45 tests, 3 suites, all passing
- **Quality gate:** 22/22 checkers pass with `--strict`

## Key Design Decision

**"Only flag what we can prove is an Array"** rather than "flag everything except known non-Arrays." This inverts the burden of proof — we only report when we have high confidence the pattern is genuinely quadratic. False negatives are acceptable for an advisory checker; false positives erode trust.

## Suppression System

Users can annotate intentional patterns with:
```swift
// complexity-ok: reason
return a.filter { b.contains($0) }
```

The comment applies to the next line. Trailing comments on the same line also work.

## What's Next

- Tier 3: Recursion classification (models are in place, analyzer not yet wired)
- Tier 4: IJS corpus integration for complexity trend analysis
- Consider: per-module threshold tuning once we have trend data
