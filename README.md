# quality-gate-swift

Modular, AST-powered static analysis for Swift projects. Enforce correctness, safety, concurrency, documentation, and security — with structured output for CI and GitHub Code Scanning.

23 checkers. 853 tests. Zero regex shortcuts — every rule walks the SwiftSyntax AST for precise, low-false-positive detection.

## Highlights

- **AST-first analysis** — SwiftSyntax-based visitors instead of regex, so rules understand scope, type context, and control flow
- **Modular architecture** — each checker is an independent SPM module with its own test suite and DocC documentation
- **Structured output** — terminal, JSON, and SARIF 2.1.0 for GitHub Code Scanning integration
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
    .package(url: "https://github.com/jpurnell/quality-gate-swift.git", from: "2.0.0"),
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

# Generate initial project status documents
quality-gate --check status --bootstrap
```

## Checkers

### Correctness

| ID | Module | Description |
|----|--------|-------------|
| `recursion` | RecursionAuditor | Self-forwarding inits, computed property cycles, mutual recursion via call-graph analysis |
| `pointer-escape` | PointerEscapeAuditor | Unsafe pointer escapes from `withUnsafe*` blocks |
| `concurrency` | ConcurrencyAuditor | Swift 6 strict concurrency: `@unchecked Sendable` justifications, mutable Sendable classes, actor isolation |
| `fp-safety` | FloatingPointSafetyAuditor | Floating-point exact equality, unguarded division |
| `memory-lifecycle` | MemoryLifecycleGuard | Stored Tasks without cancellation, strong delegate references |
| `unreachable` | UnreachableCodeAuditor | Dead code via SwiftSyntax + IndexStore cross-reference |

### Safety & Security

| ID | Module | Description |
|----|--------|-------------|
| `safety` | SafetyAuditor | Force unwraps, force casts, `try!`, `fatalError`, OWASP Mobile Top 10 security rules |
| `stochastic-determinism` | StochasticDeterminismAuditor | Unseeded randomness in production code |

### Code Hygiene

| ID | Module | Description |
|----|--------|-------------|
| `logging` | LoggingAuditor | `print()` in production code, silent `catch` blocks, missing os.Logger usage |
| `test-quality` | TestQualityAuditor | Floating-point assertions, missing test assertions, unseeded randomness in tests |
| `context` | ContextAuditor | Missing consent guards, unguarded analytics, surveillance patterns |
| `accessibility` | AccessibilityAuditor | SwiftUI accessibility: missing labels, fixed font sizes, color-only differentiation |

### Documentation

| ID | Module | Description |
|----|--------|-------------|
| `doc-coverage` | DocCoverageChecker | Undocumented public APIs (SwiftSyntax-based) |
| `doc-lint` | DocLinter | DocC documentation build errors |

### Project Health

| ID | Module | Description |
|----|--------|-------------|
| `build` | BuildChecker | `swift build` wrapper — captures all compiler errors and warnings |
| `test` | TestRunner | `swift test` wrapper — parses Swift Testing and XCTest results |
| `status` | StatusAuditor | Drift between project docs and actual code state; supports `--fix` |
| `dependency-audit` | DependencyAuditor | Package.resolved sync, branch pins, local overrides |
| `release-readiness` | ReleaseReadinessAuditor | CHANGELOG entries, README placeholders, bare to-do markers |
| `swift-version` | SwiftVersionChecker | swift-tools-version validation and upgrade feasibility |
| `memory-builder` | MemoryBuilder | Claude Code project memory generation and validation |

### Specialty

| ID | Module | Description |
|----|--------|-------------|
| `mcp-readiness` | MCPReadinessAuditor | MCP tool schema vs. implementation cross-reference (opt-in) |
| `disk-clean` | DiskCleaner | Build artifact and cache cleanup (opt-in) |

`mcp-readiness` and `disk-clean` are opt-in — excluded from default runs unless explicitly requested with `--check`.

## CLI reference

| Flag | Description |
|------|-------------|
| `--check <name>` | Run specific checker(s) by ID. Use `all` for every checker |
| `--exclude <name>` | Skip checker(s) when using `--check all` |
| `--format <fmt>` | Output format: `terminal` (default), `json`, `sarif` |
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

Per-checker configuration sections are available for `concurrency`, `pointerEscape`, `security`, `status`, `logging`, `dependencyAudit`, `releaseReadiness`, `fpSafety`, `stochasticDeterminism`, `memoryLifecycle`, `mcpReadiness`, and `build`.

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
│   ├── [23 checker modules]             # One module per checker (see table above)
│   └── [25 DocC catalogs]              # Per-module documentation
├── Tests/                               # 853 tests across 74 test files
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
