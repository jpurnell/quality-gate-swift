# ``ReleaseReadinessAuditor``

Catches release hygiene issues: missing changelog entries, leftover TODO markers in README, and bare TODOs in source code.

## Overview

ReleaseReadinessAuditor scans your project for common release-day oversights that slip through code review. It checks that the CHANGELOG has an entry for the current version, that the README is free of placeholder markers, and (optionally) that source-level TODOs carry issue references.

This auditor is file-based and does not require SwiftSyntax. It detects the current version by running `git describe --tags --abbrev=0`, falling back to scanning source files for `version:` or `version =` patterns. When no version can be detected, the changelog rule is silently skipped.

The auditor is designed to run in two modes. During day-to-day development, it surfaces warnings that are informational. At release time, combine it with `--strict` to promote those warnings to gate failures, ensuring nothing ships with placeholder text or an outdated changelog.

### Detected rules

| Rule ID | What it flags | Severity |
|---------|---------------|----------|
| `release-changelog` | No CHANGELOG found, or no entry matching the current version | warning |
| `release-todo-readme` | README contains TODO, FIXME, HACK, XXX, PLACEHOLDER, or custom markers | warning |
| `release-todo-sources` | Source files contain bare TODO/FIXME without issue references (when `requireIssueReference` is true) | warning |

### release-changelog

Checks that the CHANGELOG file exists at the configured path and contains a line mentioning the current version string. Version detection strips a leading `v` or `V` prefix (e.g. `v1.2.0` becomes `1.2.0`). If the version cannot be detected from git tags or source files, this rule is silently skipped rather than producing a false positive.

### release-todo-readme

Scans every line of the README for marker keywords. The default markers are `TODO`, `FIXME`, `HACK`, `XXX`, and `PLACEHOLDER`. Matching is case-insensitive. Additional markers can be added via the `additionalMarkers` configuration. One diagnostic is emitted per line, even if multiple markers appear on the same line.

### release-todo-sources

When `requireIssueReference` is enabled, scans all `.swift` files under `Sources/` for `TODO` and `FIXME` comments that lack a parenthesized reference. `TODO(#123)` and `FIXME(JIRA-456)` are accepted; bare `TODO` and `FIXME` are flagged. This enforces the practice of linking every TODO to a tracked issue so they don't become permanent fixtures. Files matching `excludePatterns` in the top-level configuration are skipped.

## Configuration

```yaml
release-readiness:
  changelogPath: "CHANGELOG.md"
  readmePath: "README.md"
  requireIssueReference: false
  additionalMarkers:
    - "TEMP"
    - "DRAFT"
```

- **`changelogPath`** (default: `"CHANGELOG.md"`) — Path to the CHANGELOG file, relative to the project root.
- **`readmePath`** (default: `"README.md"`) — Path to the README file, relative to the project root.
- **`requireIssueReference`** (default: `false`) — When true, enables the `release-todo-sources` rule requiring `TODO(#ref)` format.
- **`additionalMarkers`** (default: `[]`) — Extra marker keywords to flag in README, beyond the built-in set.

## Topics

### Essentials

- ``ReleaseReadinessAuditor/check(configuration:)``

### Guides

- <doc:ReleaseReadinessAuditorGuide>
