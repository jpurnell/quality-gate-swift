# Getting Started with ReleaseReadinessAuditor

@Metadata {
  @TechnologyRoot
}

## Overview

ReleaseReadinessAuditor prevents common release-day oversights from shipping: stale changelogs, placeholder markers in the README, and untracked TODOs in source code. It runs purely on file content and git tags, requiring no SwiftSyntax or network access.

## What It Detects

### `release-changelog` — Missing or stale changelog entry

Every release should have a corresponding CHANGELOG entry. This rule checks that the file exists and contains the current version string somewhere in its content.

```
$ quality-gate --checkers release-readiness
warning: [release-changelog] No CHANGELOG found at CHANGELOG.md
```

Or when the file exists but lacks the current version:

```
$ quality-gate --checkers release-readiness
warning: [release-changelog] CHANGELOG has no entry for version 2.1.0
```

**Fix:** Add a section for the current version:

```markdown
## 2.1.0

### Added
- FloatingPointSafetyAuditor for catching precision bugs
- DependencyAuditor for SPM hygiene checks

### Fixed
- False positive in RecursionAuditor for protocol extensions
```

The version is detected from `git describe --tags --abbrev=0`. A leading `v` prefix is stripped automatically (`v2.1.0` matches a changelog entry for `2.1.0`). If no version can be detected, the rule is silently skipped.

### `release-todo-readme` — Placeholder markers in README

Leftover TODO, FIXME, HACK, XXX, and PLACEHOLDER markers in the README signal unfinished documentation that should not ship.

```
$ quality-gate --checkers release-readiness
warning: [release-todo-readme] README contains 'TODO' marker (README.md:42)
warning: [release-todo-readme] README contains 'PLACEHOLDER' marker (README.md:67)
```

**Example README content that triggers the rule:**

```markdown
## Installation

TODO: Add installation instructions

## API Reference

See the PLACEHOLDER documentation at ...
```

**Fix:** Replace markers with actual content, or remove the placeholder sections entirely.

Matching is case-insensitive, so `todo`, `Todo`, and `TODO` all trigger the rule. Custom markers can be added via `additionalMarkers` in the configuration.

### `release-todo-sources` — Bare TODOs without issue references

When `requireIssueReference` is enabled, this rule scans all Swift files under `Sources/` for TODO and FIXME comments that lack a parenthesized tracker reference.

```
$ quality-gate --checkers release-readiness
warning: [release-todo-sources] TODO/FIXME without issue reference (Sources/Core/Parser.swift:88)
```

**Flagged (bare TODO):**

```swift
// TODO: handle edge case for empty input
// FIXME: this is a workaround
func parse(_ input: String) -> Result { ... }
```

**Accepted (with issue reference):**

```swift
// TODO(#234): handle edge case for empty input
// FIXME(PROJ-891): this is a workaround for upstream bug
func parse(_ input: String) -> Result { ... }
```

The pattern requires the marker keyword followed immediately (or with whitespace) by an opening parenthesis: `TODO(`, `FIXME(`, `TODO (`, etc. Any content inside the parentheses counts as a reference.

## Exemptions

### Skipping the changelog check

If your project does not maintain a CHANGELOG, the rule will emit a warning about the missing file. To suppress it, either create an empty CHANGELOG or disable the checker entirely via `--checkers` filtering.

### Excluding files from source TODO scanning

Files matching the top-level `excludePatterns` configuration are skipped during source TODO scanning:

```yaml
excludePatterns:
  - "**/Generated/**"
  - "**/Vendor/**"
```

### Custom marker keywords

Add project-specific markers beyond the defaults:

```yaml
release-readiness:
  additionalMarkers:
    - "TEMP"
    - "DRAFT"
    - "WIP"
```

## Configuration

Minimal configuration for day-to-day development (all defaults):

```yaml
release-readiness: {}
```

Strict release-time configuration:

```yaml
release-readiness:
  changelogPath: "CHANGELOG.md"
  readmePath: "README.md"
  requireIssueReference: true
  additionalMarkers:
    - "TEMP"
    - "DRAFT"
    - "WIP"
```

## Integration

### CLI usage

Run as part of the full quality gate:

```bash
quality-gate
```

Run only release readiness checks:

```bash
quality-gate --checkers release-readiness
```

### Release-time gating

All three rules emit warnings, not errors. During day-to-day development, warnings are informational and do not fail the gate. At release time, use `--strict` to promote warnings to failures:

```bash
quality-gate --checkers release-readiness --strict
```

This is the recommended approach: run the auditor informatively during development, then gate on it at release time.

### CI integration

Add a release-readiness gate to your release branch pipeline:

```yaml
steps:
  - name: Release readiness check
    run: quality-gate --checkers release-readiness --strict
    if: startsWith(github.ref, 'refs/heads/release/')
```

This ensures changelogs are updated and placeholder text is removed before any release branch merges.
