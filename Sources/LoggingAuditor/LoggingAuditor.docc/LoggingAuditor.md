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
  customLoggerNames: ["HarborLog", "WatchLog"]
```

**`projectType`** (`String`, default: `"application"`) -- `"application"` enables every rule. `"cli"` skips `logging.print-statement` and `logging.no-os-logger-import`, because a command-line tool's output *is* `print()`; the other rules still run. `"library"` skips the auditor entirely. Any other value is treated as `"library"` and the auditor reports `skipped`. A `cli` or `library` setting is listed under *Exclusions in force* in the run summary.

**`silentTryKeyword`** (`String`, default: `"silent:"`) -- The comment keyword that suppresses `logging.silent-try` warnings. The comment must appear on the same line as the `try?` expression or on the immediately preceding line.

**`allowedSilentTryFunctions`** (`[String]`, default: `["Task.sleep", "JSONEncoder", "JSONDecoder"]`) -- Function names where `try?` is considered safe fire-and-forget usage. If the `try?` expression text contains any of these strings, the silent-try rule is not applied.

**`customLoggerNames`** (`[String]`, default: `[]`) -- Additional logger type or instance names beyond the built-in set (`Logger`, `logger`, `log`, `NSLog`). When a custom name appears within two lines of a `try?` expression, the adjacent-logging check passes. Useful for project-specific logging wrappers.

### Suppression comments

Each rule has its own suppression mechanism:

- **`logging.print-statement`**, **`logging.missing-privacy`**, **`logging.bare-logger-init`**, **`logging.catch-without-logging`**, **`logging.no-os-logger-import`**: Add `// logging: <reason>` on the same line or the line above (line 1 of the file for `no-os-logger-import`).
- **`logging.silent-try`**: Add `// silent: <reason>` (or your configured `silentTryKeyword`) on the same line or the line above.

Both markers record an override for every finding they silence — and only for a finding
they silence: a marker beside a `try?` that is on the allow-list, or beside a logger call
that is already annotated, records nothing. Neither marker's reason is enforced, so it is
judged when the run is reported: eight words or more, not a stock phrase and not repeated in
the file is an **acknowledgement**; anything less is a **suppression**. See *Acknowledgements
are not suppressions* in `GUIDE.md`.

(Between June and October 2026 these two markers silenced without recording anything, while
this page said they recorded a `DiagnosticOverride`.)

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
