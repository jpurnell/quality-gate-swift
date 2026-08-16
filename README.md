# quality-gate-swift

Modular, AST-powered static analysis for Swift projects. Enforce correctness, safety, concurrency, documentation, and security — with structured output for CI and GitHub Code Scanning.

33 checkers. 1,732 tests. Zero regex — every rule and every manifest parser walks the SwiftSyntax AST for precise, low-false-positive detection.

## Highlights

- **AST-first analysis** — SwiftSyntax-based visitors instead of regex, so rules understand scope, type context, and control flow
- **Modular architecture** — each checker is an independent SPM module with its own test suite and DocC documentation
- **Structured output** — terminal, JSON, SARIF 2.1.0 for GitHub Code Scanning, and Xcode Build Phase format
- **Auto-fix support** — checkers implementing `FixableChecker` can patch issues automatically with `--fix`
- **Self-dogfooding** — quality-gate-swift runs its own checkers on every push via CI

## Installation

### Build from source

```bash
git clone https://github.com/jpurnell/quality-gate-swift.git
cd quality-gate-swift
swift build -c release
cp .build/release/quality-gate /usr/local/bin/
```

### SPM dependency

```swift
dependencies: [
    .package(url: "https://github.com/jpurnell/quality-gate-swift.git", from: "2.0.1"),
]
```

### SPM plugin

```bash
swift package plugin quality-gate
```

## Quick start

```bash
# Run all default checkers
quality-gate

# Run specific checkers
quality-gate --check build --check safety --check concurrency

# Run everything, skip slow checkers
quality-gate --check all --exclude build --exclude test

# Preview auto-fixes without applying
quality-gate --fix --dry-run

# Apply auto-fixes
quality-gate --fix

# SARIF output for GitHub Code Scanning
quality-gate --format sarif > results.sarif

# Xcode Build Phase integration
quality-gate --format xcode

# Generate initial project status documents
quality-gate --check status --bootstrap

# Technical-control coverage report (SOC 2 / ISO 27001 / HIPAA) — not a compliance assertion
quality-gate compliance            # human-readable
quality-gate compliance --as json  # machine-readable evidence artifact

# Detect upstream drift in the control catalogs (HIPAA via eCFR API; SOC 2 / ISO manual)
quality-gate standards-watch       # exits non-zero on drift — schedule it
```

## Checkers

### Correctness

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-correctness -->
| `unreachable` | UnreachableCodeAuditor | Dead code via SwiftSyntax + IndexStore cross-reference |
| `recursion` | RecursionAuditor | Self-forwarding inits, computed property cycles, mutual recursion via USR call-graph analysis |
| `concurrency` | ConcurrencyAuditor | Swift 6 strict concurrency: `@unchecked Sendable` justifications, mutable Sendable classes, actor isolation, cancellation checkpoints after `for await` loops |
| `pointer-escape` | PointerEscapeAuditor | Unsafe pointer escapes from `withUnsafe*` blocks |
| `fp-safety` | FloatingPointSafetyAuditor | Floating-point exact equality, unguarded division |
| `memory-lifecycle` | MemoryLifecycleGuard | Stored Tasks without cancellation, strong delegate references, cross-file lifecycle analysis |
| `process-safety` | ProcessSafetyAuditor | Pipe-buffer deadlock: waitUntilExit() before reading pipe output |
| `complexity` | ComplexityAnalyzer | Cognitive complexity per function, call-graph amplification, cross-module amplification, O(n) pattern detection |
| `legibility` | LegibilityAnalyzer | Advisory (never gates): central-but-unoriented modules, dependency cycles, over-public surface; emits a reading-order / module-map artifact |
<!-- /generated:checker-table-correctness -->

### Safety & Security

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-safety-security -->
| `safety` | SafetyAuditor | Force unwraps, force casts, `try!`, `fatalError`, OWASP Mobile Top 10 security rules |
| `stochastic-determinism` | StochasticDeterminismAuditor | Unseeded randomness in production code |
| `temporal-determinism` | TemporalDeterminismAuditor | Wall-clock nondeterminism: simulated sources stamping `.now`, and tests asserting on measured elapsed wall-clock time |
| `gpu-safety` | GPUSafetyAuditor | Metal kernels that index by thread id with no bound, and dispatches that round up — the conditions for silent out-of-bounds reads and writes |
| `keychain-secrets` | KeychainSecretsChecker | Credentials/tokens written to `UserDefaults` (plaintext plist, backup-swept) instead of the Keychain — key- and value-name secret detection with a Bool/Int-value guard |
| `privacy-manifest` | PrivacyManifestChecker | App targets missing or with a malformed `PrivacyInfo.xcprivacy` — opt-in by app detection, so pure SPM libraries are skipped |
| `hig-auditor` | HIGAuditor | Apple Human Interface Guidelines compliance for SwiftUI views |
<!-- /generated:checker-table-safety-security -->

### Code Hygiene

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-code-hygiene -->
| `accessibility` | AccessibilityAuditor | SwiftUI accessibility: missing labels, fixed font sizes, color-only differentiation |
| `logging` | LoggingAuditor | `print()` in production code, silent `catch` blocks, missing os.Logger usage |
| `test-quality` | TestQualityAuditor | Floating-point assertions, missing test assertions, unseeded randomness in tests |
| `context` | ContextAuditor | Missing consent guards, unguarded analytics, surveillance patterns |
| `idiom` | IdiomAuditor | Non-idiomatic Swift the language has a shorter form for; `// idiom:exempt` is recorded, never silent (advisory) |
| `smells` | SmellPack | Structural smells in declarations: long parameter lists, feature envy, primitive obsession; `// smell:exempt` is recorded (advisory) |
| `duplication` | DuplicationAuditor | Token-level clone detection across files and modules (advisory) |
<!-- /generated:checker-table-code-hygiene -->

### Documentation

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-documentation -->
| `doc-lint` | DocLinter | DocC documentation build errors |
| `doc-code` | DocCodeAuditor | Fenced Swift in DocC articles must compile against the built module — the article is one program |
| `doc-run` | DocCodeAuditor | DocC articles must *run* top to bottom without trapping, not merely compile — the article is one program (opt-in) |
| `doc-claims` | DocCodeAuditor | Figures a DocC article publishes must match what that article's own program computes (opt-in) |
| `doc-comment-code` | DocCodeAuditor | Fenced Swift in `///` and `/** */` doc comments must compile against the module the comment lives in — the unit is one fence (opt-in) |
| `doc-generated` | DocGeneratedAuditor | Derived content committed as prose — rosters, registries, changelog links — must still match what it was derived from |
| `doc-coverage` | DocCoverageChecker | Undocumented public APIs, inherited documentation detection, usage-priority ranking |
<!-- /generated:checker-table-documentation -->

### Project Health

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-project-health -->
| `build` | BuildChecker | `swift build` wrapper — captures all compiler errors and warnings |
| `test` | TestRunner | `swift test` wrapper — parses Swift Testing and XCTest results; flip detector flags scheduler-dependent pass↔fail outcome changes on an unchanged package; optional stress mode re-runs `// TIMING:`-tagged tests to provoke races |
| `memory-builder` | MemoryBuilder | Claude Code project memory generation and validation |
| `status` | StatusAuditor | Drift between project docs and actual code state; supports `--fix` |
| `swift-version` | SwiftVersionChecker | swift-tools-version validation and upgrade feasibility |
| `dependency-audit` | DependencyAuditor | Package.resolved sync, branch pins, local overrides, hallucinated import detection via AST-parsed manifests |
| `submodule-audit` | SubmoduleAuditor | Git submodule pin and allowlist compliance |
| `release-readiness` | ReleaseReadinessAuditor | CHANGELOG entries, README placeholders, pending-work markers |
<!-- /generated:checker-table-project-health -->

### Specialty

| ID | Module | Description |
|----|--------|-------------|
<!-- generated:checker-table-specialty -->
| `mcp-readiness` | MCPReadinessAuditor | MCP tool schema vs. implementation cross-reference |
| `control-mapping` | ControlMapping | Integrity of the SOC 2 / ISO 27001 / HIPAA technical-control mapping — phantom-rule / phantom-control / superseded-catalog errors, catalog-staleness warning |
| `appintents-readiness` | AppIntentsAuditor | App Intents entity conformance, parameter wrappers, metadata protocols |
| `consistency` | ConsistencyChecker | Institutional consistency scoring via IJS pulse and telemetry |
| `xcode-build` | XcodeBuildChecker | Xcode project build validation and IndexStore generation (opt-in) |
<!-- /generated:checker-table-specialty -->
| `disk-clean` | DiskCleaner | Build artifact and cache cleanup (opt-in) |

`disk-clean`, `xcode-build`, `doc-run`, `doc-claims` and `doc-comment-code` are opt-in — excluded from default runs unless explicitly requested with `--check` or listed in `enabledCheckers`.

`doc-code` was opt-in for a different reason than those two, and the reasoning is worth keeping because it was right at the time. It is not merely slow: it holds an article to being **one compilable program**, so every block in it concatenates and runs as a playground. That is a convention a repository adopts, and until it has, the checker reports true findings about documentation nobody agreed to write that way — 76 of them here. It now runs by default, because that bar was met rather than lowered: this catalogue stands at 0 findings across 50 articles and 152 fences, with zero `<!-- docs:illustrative -->` markers. Exclude it with `--exclude doc-code` if your own catalogue has not adopted the convention yet. `--full` still does not carry it, because `--full` means "the slow ones too", not "adopt a documentation convention you have not adopted".

`doc-comment-code` opts out for the same reason, with the number measured: on this repository it found 43 doc fences in 26 files — 20 Swift, 23 not — of which **16 failed on the day the rule was written**, ten of them one `## Usage` template copied into ten auditors. It carries its own id rather than sharing `doc-code`'s precisely so that landing it red cannot take a green `doc-code` down with it, and so the two can be repaired independently. Its preamble is `Foundation` plus the owning module and nothing widens it — not the dependency closure, not `docCode.extraImports` — because whatever a fence needs in order to compile is exactly what a reader copying it out of Quick Help has to type.

## CLI reference

| Flag | Description |
|------|-------------|
| `--check <name>` | Run specific checker(s) by ID. Use `all` for every checker |
| `--exclude <name>` | Skip checker(s) when using `--check all` |
| `--format <fmt>` | Output format: `terminal` (default), `json`, `sarif`, `xcode` |
| `--config <path>` | Config file path (default: `.quality-gate.yml`) |
| `--continue-on-failure` | Run all checks even if one fails |
| `--strict` | Treat warnings as failures (exit code 1) |
| `--verbose` | Show detailed progress |
| `--fix` | Apply auto-fixes for `FixableChecker` conformers |
| `--dry-run` | Preview `--fix` changes without writing (requires `--fix`) |
| `--bootstrap` | Generate initial status documents from project state |
| `--auto-build-xcode` | Drive `xcodebuild` for IndexStore when needed by unreachable checker |

## Configuration

Create `.quality-gate.yml` in your project root:

```yaml
parallelWorkers: 8

excludePatterns:
  - "**/Generated/**"
  - "**/Vendor/**"

safetyExemptions:
  - "// SAFETY:"

enabledCheckers:
  - build
  - test
  - safety
  - recursion
  - concurrency
  - pointer-escape

buildConfiguration: debug

concurrency:
  justificationKeyword: "Justification:"
  allowPreconcurrencyImports:
    - Alamofire

pointerEscape:
  allowedEscapeFunctions:
    - vDSP_fft_zip

security:
  enabledRules: []
  secretPatterns: [password, secret, apiKey, token, credential, privateKey]
  allowedHTTPHosts: [localhost, 127.0.0.1]
```

Per-checker configuration sections are available for `concurrency`, `pointerEscape`, `security`, `status`, `logging`, `dependencyAudit`, `releaseReadiness`, `fpSafety`, `stochasticDeterminism`, `memoryLifecycle`, `mcpReadiness`, `appIntentsReadiness`, `build`, `xcodeBuild`, `recursion`, `complexity`, `docCoverage`, `keychain-secrets`, `privacy-manifest`, and `consistency`.

Severity overrides let you downgrade or upgrade any rule:

```yaml
overrides:
  - ruleId: "force-unwrap"
    severity: warning
  - ruleId: "security.insecure-transport"
    severity: error
```

## Exemptions

Suppress specific warnings with inline comments:

```swift
// SAFETY: Guaranteed non-nil by UIKit lifecycle
let view = optionalView!

// SECURITY: Test fixture, not a real credential
let testKey = "sk-test-only"

// Justification: Sendable compliance verified via code review
struct LegacyWrapper: @unchecked Sendable { ... }
```

## CI integration

### GitHub Actions

```yaml
- name: Build Quality Gate
  run: swift build -c release

- name: Run Quality Gate
  run: .build/release/quality-gate --format sarif > results.sarif

- name: Upload SARIF
  uses: github/codeql-action/upload-sarif@v2
  with:
    sarif_file: results.sarif
```

### Pre-push hook

```bash
#!/bin/bash
quality-gate --check build --check safety
```

### Reusable workflow

A reusable GitHub Actions workflow is provided at `.github/workflows/quality-gate-reusable.yml` for use across multiple repositories.

## Documentation

Every checker module includes a DocC catalog with detailed guides. Build the documentation locally:

```bash
swift package generate-documentation --target QualityGateCore
swift package generate-documentation --target SafetyAuditor
swift package generate-documentation --target ConcurrencyAuditor
# ... any module name from the checker table above
```

For the full tutorial — design philosophy, architecture walkthrough, and integration patterns — see the **[Guide](GUIDE.md)**.

## Architecture

```
quality-gate-swift/
├── Sources/
│   ├── QualityGateCore/                 # Protocol, models, reporters, configuration
│   ├── QualityGateTestKit/              # Test helpers for writing checker tests
│   ├── QualityGateCLI/                  # Umbrella CLI entry point
│   ├── IndexStoreInfra/                  # Shared IndexStoreDB infrastructure
│   ├── IJS*/                             # Institutional Judgment System modules
│   ├── [29 checker modules]             # One module per checker (see table above)
│   └── [27 DocC catalogs]              # Per-module documentation
├── Tests/                               # 1,662 tests across 151 test files
├── Plugins/
│   └── QualityGatePlugin/              # SPM command plugin
└── .github/workflows/                   # CI, quality gate, security staleness
```

All SwiftSyntax-based checkers use AST walking for precise detection. Each checker is an independent module — depend on only what you need:

```swift
.target(
    name: "MyTool",
    dependencies: [
        .product(name: "SafetyAuditor", package: "quality-gate-swift"),
        .product(name: "ConcurrencyAuditor", package: "quality-gate-swift"),
    ]
)
```

## Requirements

- macOS 14+
- Swift 6.0+

## License

MIT — see [LICENSE](LICENSE).

## Contributing

1. Fork the repository
2. Create a feature branch
3. Ensure all checks pass: `quality-gate --check all --continue-on-failure`
4. Submit a pull request
