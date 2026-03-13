# Quality Gate CLI

Command-line interface for running automated quality checks on Swift projects.

## Installation

Build from source:

```bash
swift build -c release
cp .build/release/quality-gate /usr/local/bin/
```

## Usage

### Run All Checks

```bash
quality-gate
```

Runs all checkers in order: build, test, safety, doc-lint, doc-coverage.

### Run Specific Checks

```bash
quality-gate --check build --check test
quality-gate --check safety
```

Available checkers:
- `build` - Compile the project, report errors/warnings
- `test` - Run tests, report failures
- `safety` - Audit for forbidden patterns (!, as!, try!, fatalError)
- `doc-lint` - Validate DocC documentation
- `doc-coverage` - Find undocumented public APIs

### Output Formats

```bash
# Human-readable (default)
quality-gate --format terminal

# JSON for programmatic parsing
quality-gate --format json

# SARIF for GitHub Code Scanning
quality-gate --format sarif > results.sarif
```

### Configuration File

```bash
quality-gate --config path/to/.quality-gate.yml
```

Default: `.quality-gate.yml` in current directory.

### Options

| Flag | Description |
|------|-------------|
| `-f, --format` | Output format: terminal, json, sarif |
| `-c, --config` | Path to configuration file |
| `--check` | Specific checker(s) to run (repeatable) |
| `--continue-on-failure` | Run all checks even if one fails |
| `-v, --verbose` | Show detailed progress |
| `--version` | Show version |
| `-h, --help` | Show help |

## Configuration

Create `.quality-gate.yml` in your project root:

```yaml
# Number of parallel test workers
parallelWorkers: 8

# Files/directories to exclude
excludePatterns:
  - "**/Generated/**"
  - "**/Vendor/**"

# Patterns that suppress safety warnings
safetyExemptions:
  - "// SAFETY:"

# Which checkers to enable (empty = all)
enabledCheckers:
  - build
  - test
  - safety

# Build configuration
buildConfiguration: debug  # or release

# Test filter pattern
testFilter: "MyTests"

# Documentation target
docTarget: MyModule
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All checks passed |
| 1 | One or more checks failed |

## Examples

### CI Pipeline

```bash
# Fail fast on first error
quality-gate

# Run all checks, report all failures
quality-gate --continue-on-failure --format json > results.json
```

### Pre-commit Hook

```bash
#!/bin/bash
quality-gate --check build --check safety
```

### GitHub Actions

```yaml
- name: Quality Gate
  run: |
    swift build -c release
    .build/release/quality-gate --format sarif > results.sarif

- name: Upload SARIF
  uses: github/codeql-action/upload-sarif@v2
  with:
    sarif_file: results.sarif
```
