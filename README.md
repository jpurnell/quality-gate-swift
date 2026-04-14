# quality-gate-swift

Automated quality gate checks for Swift projects. Enforce zero warnings, zero test failures, comprehensive documentation, and security best practices — with SARIF output for GitHub Code Scanning.

## Checkers

| Checker | ID | Description |
|---------|-----|-------------|
| **Build Checker** | `build` | Runs `swift build`, catches all compiler errors and warnings |
| **Test Runner** | `test` | Runs `swift test`, parses Swift Testing and XCTest results |
| **Safety Auditor** | `safety` | Detects forbidden crash-prone patterns and OWASP security vulnerabilities |
| **Doc Linter** | `doc-lint` | Validates DocC documentation for errors |
| **Doc Coverage** | `doc-coverage` | Finds undocumented public APIs (SwiftSyntax-based) |
| **Recursion Auditor** | `recursion` | Catches infinite recursion: self-forwarding inits, computed property cycles, mutual recursion via call-graph analysis |
| **Concurrency Auditor** | `concurrency` | Enforces Swift 6 strict concurrency: `@unchecked Sendable` justifications, mutable Sendable classes, actor isolation issues |
| **Pointer Escape Auditor** | `pointer-escape` | Detects unsafe pointer escapes from `withUnsafe*` blocks |
| **Unreachable Code Auditor** | `unreachable` | Finds dead code via SwiftSyntax + IndexStore analysis |
| **Accessibility Auditor** | `accessibility` | Checks SwiftUI views for accessibility compliance |
| **Status Auditor** | `status` | Detects drift between Master Plan/docs and actual code state; supports `--fix` to auto-remediate |
| **Disk Cleaner** | `disk-cleaner` | Identifies build artifacts and caches for cleanup |

All checkers implement the `QualityChecker` protocol, produce `Diagnostic` results, and support terminal, JSON, and SARIF output. Checkers implementing `FixableChecker` also support `--fix` for auto-remediation.

## Installation

### Build from Source

```bash
git clone https://github.com/jpurnell/quality-gate-swift.git
cd quality-gate-swift
swift build -c release
cp .build/release/quality-gate /usr/local/bin/
```

### SPM Plugin (in your project)

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jpurnell/quality-gate-swift.git", from: "1.0.0"),
]
```

## Usage

### Command Line

```bash
# Run all checks
quality-gate

# Run specific checks
quality-gate --check build --check test --check safety

# JSON output for CI
quality-gate --format json

# SARIF output for GitHub Code Scanning
quality-gate --format sarif > results.sarif

# Continue even if a check fails
quality-gate --continue-on-failure
```

### SPM Plugin

```bash
swift package plugin quality-gate
swift package plugin quality-gate --check safety
```

### Options

| Flag | Description |
|------|-------------|
| `--check <name>` | Run specific checker(s) by ID (see table above) |
| `--format <fmt>` | Output format: `terminal` (default), `json`, `sarif` |
| `--config <path>` | Path to config file (default: `.quality-gate.yml`) |
| `--continue-on-failure` | Run all checks even if one fails |
| `--verbose` | Show detailed progress |
| `--fix` | Apply auto-fixes for checkers that support `FixableChecker` |
| `--dry-run` | Preview what `--fix` would change without writing (requires `--fix`) |
| `--bootstrap` | Generate initial Master Plan from actual project state (use with `--check status`) |

## Configuration

Create `.quality-gate.yml` in your project root:

```yaml
# Parallel test workers (default: 80% of CPU cores)
parallelWorkers: 8

# Files/directories to exclude
excludePatterns:
  - "**/Generated/**"
  - "**/Vendor/**"

# Patterns that suppress safety/security warnings
safetyExemptions:
  - "// SAFETY:"

# Which checkers to enable (empty = all)
enabledCheckers:
  - build
  - test
  - safety
  - recursion
  - concurrency
  - pointer-escape

# Build configuration
buildConfiguration: debug  # or release

# Test filter pattern
testFilter: "MyTests"

# Documentation target for DocC
docTarget: MyModule

# Minimum doc coverage % (nil = strict mode, any gap fails)
docCoverageThreshold: 80

# Per-checker configuration
concurrency:
  justificationKeyword: "Justification:"
  allowPreconcurrencyImports:
    - Alamofire

pointerEscape:
  allowedEscapeFunctions:
    - vDSP_fft_zip
    - vDSP_fft_zop

security:
  enabledRules: []  # empty = all 10 rules enabled
  secretPatterns:
    - password
    - secret
    - apiKey
    - token
    - credential
    - privateKey
  allowedHTTPHosts:
    - localhost
    - 127.0.0.1
  sqlFunctionNames:
    - execute
    - prepare
    - query
```

## Safety Auditor

The safety auditor runs two visitor passes on every Swift file:

### Code Safety Rules

| Pattern | Rule ID | Why It's Forbidden |
|---------|---------|-------------------|
| `!` (force unwrap) | `force-unwrap` | Crashes at runtime if nil |
| `as!` (force cast) | `force-cast` | Crashes at runtime if cast fails |
| `try!` (force try) | `force-try` | Crashes at runtime if error thrown |
| `fatalError()` | `fatal-error` | Intentional crash |
| `precondition()` | `precondition` | Crashes in release builds |
| `assertionFailure()` | `assertion-failure` | Crashes in debug builds |
| `unowned` | `unowned` | Crashes if accessed after deallocation |
| `while true` | `infinite-loop` | May run indefinitely |
| `String(format:)` | `c-style-format-string` | `%s` + Swift String = SIGSEGV |

### Security Rules (OWASP Mobile Top 10)

| Rule ID | CWE | OWASP 2024 | What It Detects |
|---------|-----|------------|-----------------|
| `security.hardcoded-secret` | CWE-798 | M1 | Secret-named variable with string literal value |
| `security.command-injection` | CWE-78 | M4 | Process/NSTask with dynamic arguments |
| `security.weak-crypto` | CWE-327 | M10 | CC_MD5, CC_SHA1, Insecure.* hash calls |
| `security.insecure-transport` | CWE-319 | M5 | http:// URLs (excluding localhost) |
| `security.eval-js` | CWE-95 | M4 | evaluateJavaScript with non-literal argument |
| `security.sql-injection` | CWE-89 | M4 | String interpolation in SQL function call |
| `security.insecure-keychain` | CWE-311 | M9 | Deprecated keychain accessibility constants |
| `security.tls-disabled` | CWE-295 | M5 | Certificate validation disabled/weakened |
| `security.path-traversal` | CWE-22 | M4 | FileManager with dynamic unsanitized path |
| `security.ssrf` | CWE-918 | M5 | URL constructed from dynamic input |

Security rules use SwiftSyntax for full AST context — they won't false-positive on `fatalError` messages, `print` statements, or doc comments (a common issue with tree-sitter scanners).

Semgrep-compatible YAML versions of these rules are available at [swift-security-rules](https://github.com/jpurnell/swift-security-rules).

### Exemptions

Add a safety or security comment to suppress warnings:

```swift
// SAFETY: Guaranteed non-nil by the framework
let value = optionalValue!

// SECURITY: Test fixture — not a real credential
let testApiKey = "sk-test-only"
```

## Status Auditor

The status auditor detects drift between your project documentation and actual code state:

| Rule ID | What It Detects |
|---------|-----------------|
| `status.module-marked-incomplete` | Module has real code but checkbox says `[ ]` |
| `status.module-marked-complete-missing` | Checkbox says `[x]` but module doesn't exist |
| `status.stub-description-mismatch` | Description says "Stub only" but module is implemented |
| `status.test-count-drift` | Documented test count differs from actual |
| `status.roadmap-phase-stale` | Phase marked "CURRENT" but all items complete |
| `status.last-updated-stale` | "Last Updated" date exceeds staleness threshold |
| `status.phantom-module` | Package.swift target not documented in Master Plan |

### Auto-Fix

StatusAuditor supports `--fix` to automatically patch provably-wrong content while preserving human-authored prose:

```bash
# See what's drifted
quality-gate --check status

# Preview fixes
quality-gate --check status --fix --dry-run

# Apply fixes (creates timestamped backups)
quality-gate --check status --fix

# Generate Master Plan from scratch for new projects
quality-gate --check status --bootstrap
```

## Output Formats

### Terminal (default)

```
==========================================
  Quality Gate Results
==========================================

✓ [build] PASSED (10.94s)
✓ [test] PASSED (45.23s)
✓ [safety] PASSED (1.24s)
✓ [recursion] PASSED (0.89s)
✓ [concurrency] PASSED (1.12s)
✓ [pointer-escape] PASSED (0.76s)
✓ [doc-coverage] PASSED (248ms)
  ℹ️  note: Documentation coverage: 100% (93/93 public APIs documented)

==========================================
✅ Quality Gate: PASSED
==========================================
```

### JSON

```json
{
  "summary": {
    "status": "passed",
    "totalChecks": 7,
    "passed": 7,
    "failed": 0
  },
  "results": [...]
}
```

### SARIF

SARIF 2.1.0 format for GitHub Code Scanning integration.

## CI Integration

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

### Security Rule Staleness

A built-in workflow checks security rule review dates bi-monthly and opens a GitHub issue when any rule exceeds its 365-day review window. See `.github/workflows/security-rule-staleness.yml`.

### Pre-commit Hook

```bash
#!/bin/bash
quality-gate --check build --check safety
```

## Architecture

```
quality-gate-swift/
├── Sources/
│   ├── QualityGateCore/          # Shared protocol, models, reporters
│   ├── SafetyAuditor/            # Code safety + OWASP security scanning
│   ├── BuildChecker/             # swift build wrapper
│   ├── TestRunner/               # swift test wrapper
│   ├── DocLinter/                # DocC documentation linter
│   ├── DocCoverageChecker/       # Undocumented API detector
│   ├── RecursionAuditor/         # Call-graph cycle detection
│   ├── ConcurrencyAuditor/       # Swift 6 concurrency compliance
│   ├── PointerEscapeAuditor/     # Unsafe pointer tracking
│   ├── UnreachableCodeAuditor/   # Dead code via SwiftSyntax + IndexStore
│   ├── AccessibilityAuditor/     # SwiftUI accessibility checks
│   ├── StatusAuditor/            # Doc drift detection + auto-fix
│   ├── MemoryBuilder/            # Project memory generation + validation
│   ├── DiskCleaner/              # Build artifact cleanup
│   └── QualityGateCLI/           # Umbrella CLI (--fix, --dry-run, --bootstrap)
└── Tests/                        # 515 tests across 64 suites
```

All SwiftSyntax-based checkers (Safety, DocCoverage, Recursion, Concurrency, PointerEscape, Unreachable, Accessibility) use AST walking for precise, low-false-positive detection.

## Requirements

- macOS 14+
- Swift 6.0+

## License

MIT

## Contributing

1. Fork the repository
2. Create a feature branch
3. Ensure all checks pass: `swift package plugin quality-gate`
4. Submit a pull request
