# ``QualityGateCLI``

Umbrella CLI that orchestrates all quality-gate checkers against a Swift project.

## Overview

QualityGateCLI is the user-facing entry point for quality-gate-swift. It parses command-line
flags, loads project configuration from `.quality-gate.yml`, resolves which checkers to run,
executes them in sequence, and reports results in the requested output format. Every checker
module in the quality-gate system (build, test, safety, docs, concurrency, recursion, pointers,
and more) is driven through this single binary.

### Quick Start

```bash
# Run default checkers (all except disk-clean)
quality-gate

# Run every registered checker
quality-gate --check all

# Run only build and safety, with verbose output
quality-gate --check build --check safety --verbose

# Preview auto-fixes without applying them
quality-gate --fix --dry-run
```

## CLI Usage

```
USAGE: quality-gate [--format <format>] [--config <config>]
                    [--check <check> ...] [--exclude <exclude> ...]
                    [--continue-on-failure] [--strict] [--verbose]
                    [--auto-build-xcode] [--fix] [--dry-run] [--bootstrap]
```

### Flags and Options

| Flag / Option | Short | Default | Description |
|---|---|---|---|
| `--check <id> ...` | | *(all except disk-clean)* | Specific checker(s) to run. Repeatable. Pass `all` to enable every registered checker. |
| `--exclude <id> ...` | | *(none)* | Checkers to skip when using `--check all`. |
| `--strict` | | `false` | Treat warnings as failures (exit code 1). |
| `--continue-on-failure` | | `false` | Continue running remaining checks after a failure instead of stopping. |
| `--fix` | | `false` | Apply auto-fixes for checkers that conform to the `FixableChecker` protocol. |
| `--dry-run` | | `false` | Show what `--fix` would change without writing to disk. Requires `--fix`. |
| `--bootstrap` | | `false` | Generate initial status documents from actual project state. Use with `--check status`. |
| `--format <format>` | `-f` | `terminal` | Output format: `terminal`, `json`, or `sarif`. |
| `--config <path>` | `-c` | `.quality-gate.yml` | Path to the YAML configuration file. |
| `--verbose` | `-v` | `false` | Print detailed progress as each checker runs. |
| `--auto-build-xcode` | | `false` | Drive `xcodebuild build` automatically when the unreachable checker cannot find a fresh DerivedData index store for an Xcode project. |
| `--version` | | | Print the version (`1.0.0`) and exit. |
| `--help` | `-h` | | Print usage information and exit. |

## Configuration File

QualityGateCLI loads project-level settings from a YAML file (default `.quality-gate.yml`
in the current directory). If the file is missing, built-in defaults are used.

```yaml
# Worker parallelism (nil = 80% of system cores)
parallelWorkers: 8

# Glob patterns for files/directories to exclude from checks
excludePatterns:
  - "**/Generated/**"
  - "**/Vendor/**"

# Comment patterns that suppress safety warnings
safetyExemptions:
  - "// SAFETY:"

# Checkers to enable (empty = all except disk-clean)
enabledCheckers:
  - build
  - test
  - safety
  - recursion
  - concurrency
  - pointer-escape

# Build configuration: debug or release
buildConfiguration: debug

# Test filter pattern
testFilter: "MyTests"

# DocC target (nil = all targets with catalogs)
docTarget: MyModule

# Minimum doc coverage percentage (nil = any gap warns)
docCoverageThreshold: 80

# Unreachable-code Xcode integration
unreachableAutoBuildXcode: false
xcodeScheme: MyApp
xcodeDestination: "generic/platform=macOS"

# Per-checker: ConcurrencyAuditor
concurrency:
  justificationKeyword: "Justification:"
  allowPreconcurrencyImports:
    - Alamofire

# Per-checker: PointerEscapeAuditor
pointerEscape:
  allowedEscapeFunctions:
    - vDSP_fft_zip

# Per-checker: SecurityVisitor (within SafetyAuditor)
security:
  enabledRules: []
  secretPatterns: ["password", "secret", "apiKey", "token"]
  allowedHTTPHosts: ["localhost", "127.0.0.1"]
  sqlFunctionNames: ["execute", "prepare", "query"]

# Per-checker: StatusAuditor
status:
  guidelinesPath: development-guidelines
  masterPlanPath: 00_CORE_RULES/00_MASTER_PLAN.md
  stubThresholdLines: 50
  testCountDriftPercent: 10
  lastUpdatedStaleDays: 90

# Per-checker: SwiftVersionChecker
swiftVersion:
  minimum: "6.2"
  checkCompiler: true

# Per-checker: MemoryBuilder
memoryBuilder:
  guidelinesPath: development-guidelines

# Per-checker: LoggingAuditor
logging:
  projectType: application
  silentTryKeyword: "silent:"
  allowedSilentTryFunctions: ["Task.sleep", "JSONEncoder", "JSONDecoder"]
  customLoggerNames: []
```

## Checker Resolution Order

The set of checkers that actually run is resolved with the following precedence
(highest wins):

1. **CLI flags** -- `--check` and `--exclude` arguments override everything.
2. **Configuration file** -- The `enabledCheckers` array in `.quality-gate.yml`.
3. **Built-in defaults** -- All registered checkers except `disk-clean`.

When `--check all` is passed, every registered checker runs. Combine with
`--exclude` to remove specific IDs from that set.

## Available Checkers

Checkers execute in registration order. The full registry and their IDs:

| ID | Name | Description |
|---|---|---|
| `build` | Build Checker | Compile the project, report errors and warnings |
| `test` | Test Runner | Run the test suite, report failures |
| `safety` | Safety Auditor | Audit for forbidden patterns (`!`, `as!`, `try!`, `fatalError`) and security rules |
| `doc-lint` | Documentation Linter | Validate DocC documentation syntax |
| `doc-coverage` | Documentation Coverage | Find undocumented public APIs |
| `unreachable` | Unreachable Code Auditor | Detect dead code via index-store analysis |
| `recursion` | Recursion Auditor | Flag accidental infinite recursion patterns |
| `concurrency` | Concurrency Auditor | Enforce Swift 6 strict concurrency rules |
| `pointer-escape` | Pointer Escape Auditor | Detect unsafe pointer lifetime escapes |
| `memory-builder` | Memory Builder | Generate CLAUDE.md memory from project state |
| `accessibility` | Accessibility Auditor | Check SwiftUI accessibility compliance |
| `status` | Status Auditor | Validate development-guidelines status documents |
| `swift-version` | Swift Version Checker | Verify swift-tools-version and compiler parity |
| `logging` | Logging Auditor | Enforce logging hygiene (silent try?, os.Logger usage) |
| `test-quality` | Test Quality Auditor | Evaluate test suite quality and patterns |
| `context` | Context Auditor | Audit context-passing patterns |
| `disk-clean` | Disk Cleaner | Remove stale build artifacts (destructive; excluded from defaults) |

## Output Formats

| Format | Flag | Use Case |
|---|---|---|
| `terminal` | `--format terminal` | Human-readable colored output for interactive use (default) |
| `json` | `--format json` | Machine-readable JSON for programmatic consumption |
| `sarif` | `--format sarif` | SARIF v2.1.0 for GitHub Code Scanning and other SARIF-compatible tools |

### CI Examples

```bash
# JSON for downstream parsing
quality-gate --continue-on-failure --format json > results.json

# SARIF for GitHub Code Scanning upload
quality-gate --format sarif > results.sarif
```

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All checks passed (or all failures were auto-fixed with `--fix`) |
| `1` | One or more checks failed (or warnings treated as failures under `--strict`) |

When `--strict` is enabled, any checker that returns a warning status is promoted to
a failure and the process exits with code 1.

When `--fix` is provided and fixes are successfully applied, the exit is 0 even if
diagnostics were originally failing.

## Topics

### Command

- ``QualityGateCLI``

### Helpers

- ``PackageManifestParser``
- ``StandardOutputStream``
