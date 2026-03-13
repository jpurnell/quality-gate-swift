# quality-gate-swift

Automated quality gate checks for Swift projects. Enforce zero warnings, zero test failures, and comprehensive documentation coverage.

## Features

- **Build Checker** — Run `swift build`, catch all compiler errors and warnings
- **Test Runner** — Run `swift test`, parse Swift Testing and XCTest results
- **Safety Auditor** — Detect forbidden patterns (`!`, `as!`, `try!`, `fatalError`, etc.)
- **Doc Linter** — Validate DocC documentation for errors
- **Doc Coverage** — Find undocumented public APIs

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
| `--check <name>` | Run specific checker(s): `build`, `test`, `safety`, `doc-lint`, `doc-coverage` |
| `--format <fmt>` | Output format: `terminal` (default), `json`, `sarif` |
| `--config <path>` | Path to config file (default: `.quality-gate.yml`) |
| `--continue-on-failure` | Run all checks even if one fails |
| `--verbose` | Show detailed progress |

## Configuration

Create `.quality-gate.yml` in your project root:

```yaml
# Parallel test workers (default: 80% of CPU cores)
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

# Documentation target for DocC
docTarget: MyModule

# Minimum doc coverage % (nil = strict mode, any gap fails)
docCoverageThreshold: 80
```

## Safety Auditor Rules

The safety auditor detects these patterns in production code:

| Pattern | Why It's Forbidden |
|---------|-------------------|
| `!` (force unwrap) | Can crash at runtime |
| `as!` (force cast) | Can crash at runtime |
| `try!` (force try) | Can crash at runtime |
| `fatalError()` | Intentional crash |
| `precondition()` | Can crash in release |
| `assertionFailure()` | Can crash in release |

### Exemptions

Add a safety comment to suppress warnings:

```swift
// SAFETY: This is guaranteed non-nil by the framework
let value = optionalValue!
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
    "totalChecks": 4,
    "passed": 4,
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

### Pre-commit Hook

```bash
#!/bin/bash
quality-gate --check build --check safety
```

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
