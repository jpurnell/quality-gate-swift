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
# Run default checkers
quality-gate

# Run every registered checker
quality-gate --check all

# Run only build and safety, with verbose output
quality-gate --check build --check safety --verbose

# Preview auto-fixes without applying them
quality-gate --fix --dry-run

# Remove build artifacts (a subcommand, not a check — it mutates the tree)
quality-gate clean --preview
quality-gate clean --gc
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
| `--check <id> ...` | | *(the default set)* | Specific checker(s) to run. Repeatable, and ids may be separated by spaces or commas: `--check a b`, `--check a --check b` and `--check a,b` mean the same thing. Pass `all` to enable every registered checker. An id that names no checker is an error (exit 64) and nothing runs. |
| `--exclude <id> ...` | | *(none)* | Checkers to skip — from the default set, from `--check all`, and from an explicit `--check`. Spaces or commas, as for `--check`. |
| `--strict` | | `false` | Treat warnings as failures (exit code 1). The run fails when the summary's `N warning(s)` is above zero. |
| `--continue-on-failure` | | `false` | Continue running remaining checks after a failure instead of stopping. |
| `--fix` | | `false` | Apply auto-fixes for checkers that conform to the `FixableChecker` protocol. |
| `--dry-run` | | `false` | Show what `--fix` would change without writing to disk. Requires `--fix`. |
| `--bootstrap` | | `false` | Generate initial status documents from actual project state. Use with `--check status`. |
| `--include-nonhermetic` | | `false` | Let time- and network-dependent checkers fail the gate. By default their findings report as notes and never block, so the same tree always yields the same verdict. |
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

# Checkers to enable (empty = all)
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
3. **Built-in defaults** -- Every registered checker except the opt-in ones.

When `--check all` is passed, every registered checker runs. Combine with
`--exclude` to remove specific IDs from that set.

`--exclude` narrows whatever was selected, an explicit `--check` included:
`--check a b --exclude b` runs `a`. The configuration's `excludedCheckers` is weaker on
purpose. It declines a checker from the default set and from `--check all`, but it does not
refuse a checker named with `--check`, so a configuration file cannot make a checker
unexaminable.

### A selection that cannot be honoured is an error

The selection is validated before anything runs.

| Selection | Result |
|---|---|
| `--check` or `--exclude` names an id that is not a checker | Exit `64`. The id is named, with the nearest real id when there is one. One bad id among good ones fails the whole invocation; there is no partial run. |
| `enabledCheckers` names an id that is not a checker | Exit `1`. Checked only when that list is what selects, so not under `--check` or `--profile`. |
| `excludedCheckers` or `includedCheckers` names an id that is not a checker | A notice on stderr. The run proceeds. |
| `--check disk-clean` | Exit `1`, with a pointer to `quality-gate clean`. `--exclude disk-clean` is accepted with a notice. |
| Every selected checker is excluded | Exit `64` when `--exclude` did it, `1` when the configuration or a `--profile` did. |

A run that examined nothing has not passed, so an empty selection never exits `0`.

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
| `1` | One or more checks failed, warnings were counted under `--strict`, the run stopped before every selected checker ran, or the configuration selects no checker |
| `64` | The command line asked for something the gate cannot do: an unknown checker id in `--check` or `--exclude`, or an `--exclude` that removes everything selected |

### What `--strict` gates on

Under `--strict` the run fails when the summary's warning count is above zero. The count
and the verdict are read from one tally (`RunTally`), so a run that prints
`0 error(s), N warning(s)` with `N` above zero exits 1 and prints
`❌ Quality Gate: FAILED (--strict: N warnings)`.

Which checker emitted the warning does not matter, and neither does the status that checker
chose for itself. Each result's status is reconciled with its diagnostics as it leaves the
runner: a checker that reports `PASSED` while carrying a warning is shown as `WARNING`.
A checker that carries an error is shown as `FAILED` and fails the run, with or without
`--strict`.

A skipped checker's warning counts too. `doc-code` and `doc-comment-code` skip with a
`module-unavailable` warning when the module they compile against has not been built. The
checker still reads `SKIPPED`, but the warning is counted, so
`quality-gate --strict --check doc-code` on a cold `.build` exits 1. Run `build` first.

`--strict` does not see warnings that were never emitted, or a finding a checker reports as
a note.

When `--fix` is provided and fixes are successfully applied, the exit is 0 even if
diagnostics were originally failing.

## Topics

### Command

- ``QualityGateCLI``

### Helpers

- ``PackageManifestParser``
- ``StandardOutputStream``
