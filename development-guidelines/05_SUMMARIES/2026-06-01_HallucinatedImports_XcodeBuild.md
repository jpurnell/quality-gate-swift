# Session Summary: Hallucinated Import Detection + Xcode Build Checker

**Date:** 2026-06-01
**Scope:** Two new checkers for quality-gate-swift
**Branch:** main
**Commits:** `b4fe262`, `ef03e3c`

---

## What Was Done

### 1. XcodeBuildChecker (new module)

Added `Sources/XcodeBuildChecker/XcodeBuildChecker.swift` — wraps `xcodebuild build` for
projects that need Xcode-specific compilation (UIKit, WatchKit, etc.) beyond what `swift build`
covers.

- Runs per destination from `.quality-gate.yml` config (`xcodeBuild.destinations`)
- Auto-discovers `.xcworkspace` or `.xcodeproj` if no project specified
- Reuses `BuildChecker.parseBuildOutput()` for diagnostic extraction
- Behind `--full` flag (opt-out by default since it's slow)
- Configuration added to `QualityGateCore/Configuration.swift` as `XcodeBuildCheckerConfig`

### 2. dep-hallucinated-import Rule (DependencyAuditor extension)

Detects `import X` where X doesn't exist in the project's dependency graph — a common AI
coding agent failure mode. Catches hallucinated packages, misspelled frameworks, or imports
from a different project context before the slow `swift build` step.

**Known modules set built from:**
- Target names from all Package.swift files (monorepo recursive discovery)
- `.product(name:)` references from dependency declarations
- Explicit `.package(name:)` parameters (old SPM API)
- Package.resolved pin identities with PascalCase derivation
- URL-derived names from Package.resolved `location` fields
- URL-derived names from `.package(url:)` declarations
- ~110 Apple/system frameworks including C modules (zlib, CommonCrypto, SQLite3)
- User-configured `additionalKnownModules` allowlist

**False positive prevention:**
- Skips `#if canImport(X)` guarded imports
- Skips imports inside multi-line string literals (`"""..."""`)
- Respects `exclude:` paths from Package.swift targets (vendored dependency test files)
- Handles both v1 and v2/v3 Package.resolved formats
- Handles `.package(name:, url:)` format (older SPM API)

**Severity:** warning

### 3. Master Plan Update

Added XcodeBuildChecker, HIGAuditor, and ComplexityAnalyzer to the master plan checklist.
Updated test count from 1,130 to 1,491 across 28 modules and 192 suites.

---

## Motivation

Prompted by HN discussion around [aislop](https://github.com/scanaislop/aislop) (73 pts,
zero Swift support). "Hallucinated imports" is a high-signal AI-slop pattern that positions
quality-gate-swift in the emerging AI code quality category.

Also discovered that LoggingAuditor already has bare-catch detection
(`logging.catch-without-logging`), which covers the other common AI-slop pattern.

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Pure regex, no SwiftSyntax | DependencyAuditor has zero SwiftSyntax dependency; import statements are trivially parseable |
| Monorepo-first design | narbis has no root Package.swift; packages are siblings — scanner discovers all Package.swift recursively |
| v1 Package.resolved parser | polar-ble-sdk uses v1 format; needed JSONSerialization fallback |
| Exclude path respect | polar-ble-sdk excludes iOS/ios-communications/Tests/ but those files still exist on disk |
| Multi-line string skip | Test files embed Swift code as string literals; regex can't distinguish from real imports |

---

## Verification

1. 45 DependencyAuditor tests pass (16 suites)
2. Full quality-gate passes on quality-gate-swift: 0 errors, 0 warnings
3. `quality-gate --check dependency-audit` passes clean in narbis monorepo
4. Manual: `import HallucinatedFakeModule` correctly flagged, then reverted

---

## Files Changed

**New:**
- `Sources/XcodeBuildChecker/XcodeBuildChecker.swift`

**Modified:**
- `Sources/DependencyAuditor/DependencyAuditor.swift` — hallucinated import rule + helpers
- `Sources/QualityGateCore/Configuration.swift` — XcodeBuildCheckerConfig, additionalKnownModules
- `Sources/QualityGateCLI/QualityGateCLI.swift` — --full flag, XcodeBuildChecker registration
- `Tests/DependencyAuditorTests/DependencyAuditorTests.swift` — 9 new test suites
- `Package.swift` — XcodeBuildChecker target + dependency
- `development-guidelines/00_CORE_RULES/00_MASTER_PLAN.md` — 3 checkers added, test count updated
