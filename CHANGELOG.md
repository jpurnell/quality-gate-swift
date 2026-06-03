# Changelog

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
