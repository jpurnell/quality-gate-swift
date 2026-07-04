# Changelog

## [Unreleased]

- **Index-store production restored under Swift 6.4 (`swiftbuild` default)**: Swift 6.4's SwiftPM changed the default `--build-system` to `swiftbuild` (the integrated XCBuild engine), which does **not** honor `-Xswiftc -index-store-path` — it emits no queryable index store. This silently broke every cross-module index checker (`unreachable`, `complexity`, `recursion`, `concurrency`, `doc-coverage`): a freshly built fixture index had **0 units / 0 records**, so cross-module dead-code detection found no symbols (5 `UnreachableCodeAuditor` tests failed). Presented as "worked for a week, broke just now" because the previously cached index (built by the older `native` system) was only now regenerated. `StoreLocator.build` now forces `--build-system native` (108 units / 1982 records restored; `native` is deprecated — follow-up: adopt the swiftbuild index mechanism before removal). Separately, `IndexStoreSession.findLibIndexStore` now resolves `libIndexStore.dylib` from the **active** toolchain (`xcode-select`) instead of preferring a hardcoded `/Applications/Xcode.app` path (missing on Xcode-beta-only machines, where it fell back to a mismatched Command Line Tools library), and fixes a `usr/usr/lib` path bug in the `xcrun` fallback.
- **Parallel checker execution (gate speed, Lever 1)**: the CLI ran its ~28 checkers strictly sequentially, so wall-time was the sum of every checker (profiled: 106 s summed vs. a 28 s slowest single checker). New `CheckerRunner` (QualityGateCore) runs checkers in a bounded `withTaskGroup` (concurrency = active processor count) and returns results in checker order. Checkers are partitioned by a new `QualityChecker.isParallelSafe` property (default `true`): checkers that spawn `swift build`/`swift test` and lock the SwiftPM `.build` directory — `build`, `test`, `xcode-build` — plus `disk-clean` (which deletes `.build`) run **sequentially**, outside the group; the pure AST/file checkers run concurrently. This partition is required for correctness: naive parallelism contends on the `.build` lock and measured *slower* (492 s). Same checks, same diagnostics, same pass/fail — 10 new tests including concurrency and isolation proofs. `continueOnFailure` semantics preserved (a failing sequential checker skips the parallel phase; a failing parallel checker cancels the group). Measured (release binary): the 20 pure-AST checkers hit **2.2×** (19.0 s → 8.8 s, near the 2.5× ceiling set by the slowest single checker); the full parallel-safe set is **1.8×** (72.9 s → 40.9 s). The remaining headroom is the index-dependent checkers (`complexity`, `recursion`, `concurrency`, `unreachable`, `doc-coverage`) serializing on the shared `libIndexStore` — a follow-up (shared/concurrent index session) tracked separately.
- **ReleaseReadinessAuditor**: corrected the version/tag hygiene invariant. Two new rules — `release-untagged-version` (error): the latest *documented* CHANGELOG version must have a matching git tag; and `release-unresolvable-dependency` (error): every README-advertised `from:` / `.exact(` dependency version must resolve to an existing tag. Previously the auditor only checked whether the newest tag was *mentioned* in the CHANGELOG (a substring test, wrong direction), so a CHANGELOG racing ahead of its tags — the most common release-hygiene failure — went undetected. Adds pure, unit-tested functions (`parseLatestChangelogVersion`, `checkVersionTagParity`, `parseReadmeDependencyVersions`, `checkDependencyVersionsResolvable`) with 22 new tests, and two opt-out config flags (`checkVersionTagParity`, `checkDependencyResolvability`), both default-on. Uses the `[Unreleased]` convention: pending work sits here (skipped by the tag-parity check) and is promoted to a version heading when tagged.

## 2.0.1

- Dashboard TUI: removed the left/right vertical border edges (`│`) from every view (portfolio, project detail, group detail, pulse sections). Selecting and copying multi-line content — the weekly narrative especially — no longer drags box-drawing pipes into the clipboard, so narratives paste as clean shareable text. Visual ordering is preserved by full-width horizontal section rules and a titled top rule (`── IJS Portfolio Dashboard ──…`) instead of a four-sided box. Chrome logic centralized in `DashboardChrome` (`titleRule` / `sectionRule` / `contentRow`), collapsing four duplicated `boxRow` helpers into one.
- HIGAuditor context-menus rule: no longer false-positives on `List { ... }` views whose rows are delegated to extracted `@ViewBuilder` computed properties (a common SwiftUI pattern the AST visitor could not follow into) or on static Lists with no repeating items. The rule now fires only on Lists that actually produce rows — data-driven (`List(items) { ... }`) or containing a direct `ForEach` — matching its documented "List/ForEach items" intent. Genuine inline misses are still flagged.
- Checker selection: `disk-clean` (a destructive maintenance task that deletes `.build/` and runs `git gc`) is now opt-in — excluded from `--check all` unless explicitly named (`--check all --check disk-clean` or `--check disk-clean`). Previously `--check all` silently wiped the build cache and index store mid-gate, which made consecutive runs non-reproducible and spuriously errored index-store-dependent checkers. Selection logic extracted to `CheckerSelection` (QualityGateCore) with unit tests.
- Self-compliance: brought the tool's own source into compliance with the logging Rule 8 (`logging.unguarded-os-import`) added in 2.0.0 by wrapping every `import os` in `#if canImport(os) ... #endif` (62 files). The package targets macOS only, so this is a no-op at build time; it keeps the tool honest against its own checker. Also refreshed MASTER_PLAN test counts / auditor inventory to clear `status` drift.

## 2.0.0

- ComplexityAnalyzer Pass 2: cross-module cognitive complexity amplification via IndexStoreDB call graph resolution, 3x loop multiplier, cycle-safe visited set
- DocCoverageChecker Pass 2: inherited documentation detection from protocol requirements, usage-priority ranking by reference count, adjusted effective coverage reporting
- MemoryLifecycleGuard Pass 2: cross-file task cancellation, delegate retention detection, stream termination analysis, stale exemption cleanup
- DependencyAuditor: replaced all 6 NSRegularExpression patterns with SwiftSyntax AST parsing (ManifestParser + ImportVisitor); each manifest parsed once instead of 3x
- XcodeReporter: Xcode Build Phase integration with `--format xcode` output
- Configuration: DocCoverageConfig, MemoryLifecycleConfig.useIndexStore, ComplexityAnalyzerConfig cross-module fields
- CrossModuleCallEdge model, FunctionComplexityRecord amplified complexity fields, ComplexityBasis cross-module case
- All Pass 2 modules degrade gracefully when index store is unavailable
- 1662 tests across 211 suites, quality gate 0/0

## 1.2.0

- IndexStoreInfra shared module: ProjectKind, StoreLocator, IndexStoreSession, ConformanceQuery, SourceWalker
- RecursionAuditor Pass 2: USR-based call graph with iterative Tarjan SCC, cross-module and protocol witness cycle detection, syntactic base case scanning
- ConcurrencyAuditor Pass 2: cross-file Sendable stored property, isolation crossing, and preconcurrency import analysis (stub queries, pure analysis tested)
- AppIntentsAuditor: opt-in checker for App Intents readiness (entity conformance, parameter wrappers, metadata protocols)
- Configuration: RecursionAuditorConfig.useIndexStore, ConcurrencyAuditorConfig.useIndexStore/trackIsolationDepth
- Iterative Tarjan SCC algorithm handles 1000+ node graphs without stack overflow
- Pass 2 base case scanning reads cycle participant source for guard statements
- DocC articles for IndexStoreInfra and AppIntentsAuditor
- 5 design proposals for checker IndexStoreDB upgrade candidates
- 1556 tests across 205 suites, quality gate 0/0

## 1.1.0

- XcodeBuildChecker, HIGAuditor, ComplexityAnalyzer call-graph amplification
- Institutional Judgment System (IJS) with pulse, telemetry, and consistency scoring
- Anti-gaming mitigants: red-team dissent, conviction flags, minimum-deliberation windows
- IJSDashboardCore module with health timeline and portfolio rendering
- Hallucinated import detection in DependencyAuditor
- Master Plan tracking and status auditing

## 1.0.0

- 23 checkers across correctness, safety, security, documentation, accessibility, and project health
- 853 tests across 74 test files
- Zero-warning self-audit: all checkers pass clean against the quality-gate-swift codebase
- Comprehensive DocC catalogs for all 25 modules
- CLI with `--check all`, `--exclude`, `--strict`, `--continue-on-failure` flags
- JSON, SARIF, and terminal output formats
- `--fix` and `--dry-run` for auto-fixable checkers
- `--bootstrap` for generating initial status documents
- Severity override system: downgrade or upgrade any rule via `.quality-gate.yml`
- `--auto-build-xcode` for IndexStore generation in Xcode projects
- `QualityGateTestKit` module for writing checker tests
- Reusable GitHub Actions workflow for cross-repo adoption
- Security rule staleness workflow with automated issue creation
- Guide document covering vision, design philosophy, architecture, and integration patterns
