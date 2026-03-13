# ``DocLinter``

Validates DocC documentation by running `swift package generate-documentation` and parsing diagnostics.

## Overview

DocLinter integrates with Swift's documentation compiler to catch documentation issues early. It detects problems like:

- Unresolved symbol references (broken links)
- Invalid documentation syntax
- Missing required documentation sections
- Malformed code examples

### How It Works

1. Executes `swift package generate-documentation`
2. Captures stdout and stderr for diagnostic messages
3. Parses output using regex to extract structured diagnostics
4. Returns a `CheckResult` with pass/fail status

### Diagnostic Format

DocLinter recognizes two diagnostic formats:

**With file location:**
```
/path/to/Sources/Module/File.swift:10:5: warning: No documentation for 'myFunc'
```

**Simple format:**
```
warning: 'MyType' doesn't exist at '/MyModule/MyType'
```

Each diagnostic includes:
- **Severity** - error, warning, or note
- **Message** - Description of the issue
- **File/Line/Column** - Location when available

### Configuration

Configure via `.quality-gate.yml`:

```yaml
docTarget: MyModule  # Optional: lint specific target only
```

### Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| 0 | Documentation builds with no errors |
| 1 | Documentation has warnings (configurable) |
| 2 | Documentation has errors |

## Topics

### Essentials

- ``DocLinter/check(configuration:)``
- ``DocLinter/parseDocCOutput(_:)``
- ``DocLinter/createResult(output:exitCode:duration:)``

### Configuration

- ``DocLinter/docArguments(for:)``
