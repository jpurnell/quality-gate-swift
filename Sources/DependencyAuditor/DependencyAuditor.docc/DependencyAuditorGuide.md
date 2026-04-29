# Getting Started with DependencyAuditor

@Metadata {
  @TechnologyRoot
}

## Overview

DependencyAuditor catches SPM dependency hygiene problems that silently break reproducible builds. It parses `Package.resolved` JSON and `Package.swift` without touching the network, making it safe to run in CI, air-gapped environments, and pre-commit hooks.

## What It Detects

### `dep-unresolved` — Missing or stale Package.resolved

The most common cause of "works on my machine" in SPM projects is a missing or outdated `Package.resolved`. This rule catches both cases.

**Missing `Package.resolved`:**

```
$ quality-gate
error: [dep-unresolved] Package.resolved is missing — run `swift package resolve`
```

This fires when the file does not exist at all. The fix is straightforward:

```bash
swift package resolve
git add Package.resolved
```

**Out-of-sync `Package.resolved`:**

```
$ quality-gate
error: [dep-unresolved] Package.resolved is out of sync with Package.swift
  (resolved has 3 pins, Package.swift declares 5 direct dependencies)
  — run `swift package resolve`
```

This fires when you've added a new `.package(url:)` dependency to `Package.swift` but haven't re-resolved. The resolved file can legitimately have *more* pins than direct dependencies (transitive deps), but fewer pins always indicates a problem.

### `dep-branch-pin` — Branch pins instead of version tags

Branch-pinned dependencies track a moving target. Every `swift package resolve` can pull different code, and upstream breaking changes arrive without warning.

```
$ quality-gate
warning: [dep-branch-pin] 'my-library' is pinned to branch 'main' instead of a version tag
```

The `Package.resolved` entry for a branch-pinned dependency looks like this:

```json
{
  "identity": "my-library",
  "kind": "remoteSourceControl",
  "location": "https://github.com/org/my-library.git",
  "state": {
    "branch": "main",
    "revision": "abc123..."
  }
}
```

**Fix:** Pin to a tagged version in `Package.swift`:

```swift
// Before — branch pin
.package(url: "https://github.com/org/my-library.git", branch: "main")

// After — version pin
.package(url: "https://github.com/org/my-library.git", from: "1.2.0")
```

### `dep-local-override` — Active swift package edit

`swift package edit` replaces a resolved dependency with a local checkout. This is indispensable for development but must not be committed or left active during release builds.

```
$ quality-gate
warning: [dep-local-override] `swift package edit` overrides are active
  — ensure these are intentional before committing
```

The auditor detects this by inspecting `.swiftpm/workspace/state.json` for `"edited"` or `"isEdited"` markers.

**Fix:** When you're done developing against the local checkout:

```bash
swift package unedit my-dependency
```

## Exemptions

### Allowing specific branch pins

Some dependencies legitimately need branch pins — internal libraries during active development, or dependencies that don't publish tags. Add their package identities (the lowercased name from `Package.resolved`) to `allowBranchPins`:

```yaml
dependency-audit:
  allowBranchPins:
    - "swift-syntax"
    - "my-internal-lib"
```

### Offline mode

The auditor runs fully offline by default. The `offlineMode` configuration key is reserved for future network-based checks (e.g., checking whether pinned versions are behind the latest release). No network calls are made regardless of this setting in the current version.

## Configuration

Minimal configuration — most projects need no configuration at all:

```yaml
dependency-audit: {}
```

Full configuration with all options:

```yaml
dependency-audit:
  maxMajorVersionsBehind: 2
  allowBranchPins:
    - "swift-syntax"
  offlineMode: true
```

## Integration

### CLI usage

Run the dependency auditor as part of the full quality gate:

```bash
quality-gate
```

Run only the dependency auditor:

```bash
quality-gate --checkers dependency-audit
```

### CI integration

Add to your CI pipeline to catch dependency issues before merge:

```yaml
steps:
  - name: Check dependency hygiene
    run: quality-gate --checkers dependency-audit --strict
```

The `dep-unresolved` rule emits errors (not warnings), so it will fail the gate even without `--strict`. The `dep-branch-pin` and `dep-local-override` rules emit warnings, which only fail the gate when `--strict` is active.

### Pre-commit hook

```bash
#!/bin/sh
quality-gate --checkers dependency-audit
```

This is particularly useful for catching forgotten `swift package edit` overrides before they reach the repository.
