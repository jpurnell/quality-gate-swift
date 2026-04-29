# ``DependencyAuditor``

Audits SPM dependency hygiene without touching the network.

## Overview

DependencyAuditor inspects your project's `Package.resolved` and `Package.swift` to catch dependency management issues that silently break reproducible builds. It parses the `Package.resolved` JSON (v2/v3 format) and cross-references it against the `.package(url:)` declarations in `Package.swift`.

Unlike most quality-gate checkers, DependencyAuditor does not use SwiftSyntax. It operates entirely on JSON parsing and file-system inspection, making it fast and dependency-light. It runs offline by default and never resolves packages against the network.

The three rules target the most common dependency hygiene failures in SPM projects: missing or stale lockfiles that make builds non-reproducible, branch pins that track a moving target instead of a stable version, and forgotten `swift package edit` overrides that can accidentally ship local source changes.

### Detected rules

| Rule ID | What it flags | Severity |
|---------|---------------|----------|
| `dep-unresolved` | `Package.resolved` missing or out of sync with `Package.swift` | error |
| `dep-branch-pin` | Dependency pinned to a branch instead of a version tag | warning |
| `dep-local-override` | `swift package edit` overrides are active | warning |

### dep-unresolved

This rule fires in two cases. First, when `Package.resolved` is missing entirely — meaning the project has never been resolved and builds are not reproducible across machines. Second, when `Package.resolved` has fewer pins than `Package.swift` declares direct dependencies, indicating the lockfile is stale. Transitive dependencies may add extra pins beyond the direct count, so the check only flags when resolved has *fewer* pins than expected.

### dep-branch-pin

A dependency pinned to a branch (e.g. `main`, `develop`) instead of a semantic version tag means every `swift package resolve` can pull different code. This breaks build reproducibility and can introduce breaking changes silently. The rule inspects the `state.branch` field of each pin in `Package.resolved`. Dependencies listed in `allowBranchPins` are exempted.

### dep-local-override

Running `swift package edit <dependency>` creates workspace state that overrides the resolved version with a local checkout. This is useful during development but dangerous if committed or left active during CI. The rule checks `.swiftpm/workspace/state.json` for `"edited"` or `"isEdited"` markers.

## Configuration

```yaml
dependency-audit:
  maxMajorVersionsBehind: 2
  allowBranchPins:
    - "swift-syntax"
    - "my-internal-lib"
  offlineMode: true
```

- **`maxMajorVersionsBehind`** (default: `2`) — Maximum major versions behind latest before flagging. Reserved for future version-staleness checking.
- **`allowBranchPins`** (default: `[]`) — Package identities (lowercased) that are permitted to use branch pins without triggering `dep-branch-pin`.
- **`offlineMode`** (default: `true`) — When true, the auditor never makes network calls. Set to false to enable future network-based checks.

## Topics

### Essentials

- ``DependencyAuditor/check(configuration:)``

### Guides

- <doc:DependencyAuditorGuide>
