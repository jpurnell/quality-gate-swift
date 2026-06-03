# Changelog

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
