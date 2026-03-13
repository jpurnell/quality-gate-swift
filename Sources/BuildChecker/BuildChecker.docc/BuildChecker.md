# ``BuildChecker``

Executes `swift build` and parses compiler diagnostics into structured results.

## Overview

BuildChecker runs the Swift compiler and extracts errors, warnings, and notes from its output. This enables CI pipelines and quality gates to programmatically check for build issues.

### How It Works

1. Executes `swift build` with the configured options
2. Captures both stdout and stderr (Swift outputs diagnostics to stderr)
3. Parses the output using regex to extract structured diagnostics
4. Returns a `CheckResult` with pass/fail status and detailed diagnostics

### Diagnostic Format

BuildChecker parses the standard Swift compiler output format:

```
/path/to/File.swift:42:15: error: cannot find 'foo' in scope
    let x = foo
            ^~~
```

Each diagnostic includes:
- **File path** - Full path to the source file
- **Line and column** - Exact location of the issue
- **Severity** - error, warning, or note
- **Message** - The compiler's description of the issue

### Configuration

Configure via `.quality-gate.yml`:

```yaml
build_configuration: release  # or debug (default)
```

## Topics

### Essentials

- ``BuildChecker/check(configuration:)``
- ``BuildChecker/parseBuildOutput(_:)``
- ``BuildChecker/createResult(output:exitCode:duration:)``

### Configuration

- ``BuildChecker/buildArguments(for:)``
