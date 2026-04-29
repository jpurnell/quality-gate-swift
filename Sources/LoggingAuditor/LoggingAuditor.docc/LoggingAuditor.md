# ``LoggingAuditor``

Enforces logging hygiene in application projects by catching `print()` in production code, silent `try?` without error logging, and missing `os` imports.

## Overview

LoggingAuditor uses SwiftSyntax to walk Swift source files under `Sources/` and apply three rules that promote structured logging over ad-hoc console output. It tracks `import os` declarations, `print()`/`NSLog()` calls, and `try?` expressions to produce actionable diagnostics.

This auditor is **gated by project type**. When `projectType` is set to `"library"`, the auditor returns `.skipped` immediately -- libraries intentionally omit logging, and consumers decide what to log. Only `"application"` projects are checked.

Test files (paths containing `Tests`) and paths matching `excludePatterns` in the gate-wide configuration are automatically skipped.

### Detected rules

| Rule ID | Severity | What it catches |
|---------|----------|-----------------|
| `logging.print-statement` | error | `print()` or `debugPrint()` calls in production code |
| `logging.silent-try` | warning | `try?` without adjacent error logging or suppression comment |
| `logging.no-os-logger-import` | warning | File uses `print()`/`NSLog()` but does not `import os` |

### Configuration

LoggingAuditor is configured via `LoggingAuditorConfig` in `.quality-gate.yml`:

```yaml
logging:
  projectType: application
  silentTryKeyword: "silent:"
  allowedSilentTryFunctions: ["Task.sleep", "JSONEncoder", "JSONDecoder"]
  customLoggerNames: ["NarbisLog", "WatchLog"]
```

**`projectType`** (`String`, default: `"application"`) -- Set to `"library"` to skip the auditor entirely. Any other value enables all rules.

**`silentTryKeyword`** (`String`, default: `"silent:"`) -- The comment keyword that suppresses `logging.silent-try` warnings. The comment must appear on the same line as the `try?` expression or on the immediately preceding line.

**`allowedSilentTryFunctions`** (`[String]`, default: `["Task.sleep", "JSONEncoder", "JSONDecoder"]`) -- Function names where `try?` is considered safe fire-and-forget usage. If the `try?` expression text contains any of these strings, the silent-try rule is not applied.

**`customLoggerNames`** (`[String]`, default: `[]`) -- Additional logger type or instance names beyond the built-in set (`Logger`, `logger`, `log`, `NSLog`). When a custom name appears within two lines of a `try?` expression, the adjacent-logging check passes. Useful for project-specific logging wrappers.

### Suppression comments

Each rule has its own suppression mechanism:

- **`logging.print-statement`**: Add `// logging:` on the same line or the line above. This records a `DiagnosticOverride` instead of a diagnostic.
- **`logging.silent-try`**: Add `// silent:` (or your configured `silentTryKeyword`) on the same line or the line above.

The comment must be a line comment (`//`), not a block comment. Blank lines between the comment and the flagged expression break adjacency.

### Out of scope

- Cross-module logging analysis (would require IndexStore)
- Detecting misuse of `os.Logger` subsystem/category naming
- Flagging `NSLog` as an error (it is only tracked for the `no-os-logger-import` rule)
- Validating that `do/catch` blocks actually log the caught error

## Topics

### Essentials

- ``LoggingAuditor/check(configuration:)``
- ``LoggingAuditor/auditSource(_:fileName:configuration:)``

### Guides

- <doc:LoggingAuditorGuide>
