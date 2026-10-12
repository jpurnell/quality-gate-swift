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

### Target Selection

By default every target owning a `.docc` catalogue is handed to DocC, one `--target`
each. A package where no target owns one is an error, not a pass: a checker that
examined nothing and a checker that found nothing wrong must not report the same thing.

Configure via `.quality-gate.yml`:

```yaml
docTarget: MyModule  # Optional: lint this target alone
```

Setting `docTarget` narrows the run to one target and says nothing about the rest, so
the run reports how many catalogues went unexamined.

### Verdict

``DocLinter/createResult(run:duration:)`` fails the check when the documentation
build exits non-zero, or when any parsed diagnostic has error severity. Warnings are
reported and do not fail the check on their own — a package can carry DocC warnings and
still pass `doc-lint`, though the gate's own `--strict` mode escalates them.

A failed check always carries a finding. Two of them are not about the documentation:

| Rule | What happened |
|---|---|
| `doc-lint-timeout` | The documentation build was stopped at its time budget. |
| `doc-lint-unparsed-failure` | The build exited non-zero and printed no error this checker can parse. |

Both state the budget and where it came from, the elapsed time, the machine's 1-minute load
average and the tool's last lines. A stopped build is never cached.

### Time Budget

The budget is three times the last successful documentation build in this checkout, never less
than 900 seconds, and 3,600 seconds when nothing is recorded. To set it instead:

```yaml
budgets:
  doc-lint: 2400   # seconds, used exactly as written
```

## Topics

### Essentials

- ``DocLinter/check(configuration:)``
- ``DocLinter/parseDocCOutput(_:)``
- ``DocLinter/createResult(run:duration:)``
- ``DocLinter/createResult(output:exitCode:duration:)``

### Configuration

- ``DocLinter/docArguments(for:)``
