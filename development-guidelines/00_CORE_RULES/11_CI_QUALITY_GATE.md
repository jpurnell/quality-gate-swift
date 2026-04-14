# CI Quality Gate Integration

**Purpose:** Every project using development-guidelines must run the quality gate in CI. Improvements propagate automatically — no version pins, no manual updates.

---

## Required Workflow

Add this to your project's `.github/workflows/`:

```yaml
# .github/workflows/quality-gate.yml
name: Quality Gate

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  quality-gate:
    uses: jpurnell/quality-gate-swift/.github/workflows/quality-gate-reusable.yml@main
```

This single line gives your project:
- **Build checking** — zero compiler warnings
- **Test running** — zero test failures
- **Safety auditing** — no force unwraps, no crash-prone patterns
- **Security scanning** — 10 OWASP Mobile Top 10 rules
- **Doc coverage** — undocumented public APIs flagged
- **Doc linting** — DocC validation
- **Recursion detection** — infinite recursion via call-graph analysis
- **Concurrency auditing** — Swift 6 strict concurrency compliance
- **Pointer safety** — unsafe pointer escape detection
- **Dead code detection** — unreachable code via IndexStore
- **Accessibility auditing** — SwiftUI accessibility compliance
- **Status drift detection** — Master Plan vs actual code state

### Running specific checks only

```yaml
jobs:
  quality-gate:
    uses: jpurnell/quality-gate-swift/.github/workflows/quality-gate-reusable.yml@main
    with:
      checks: "build test safety status"
```

### With custom configuration

Create `.quality-gate.yml` in your project root:

```yaml
excludePatterns:
  - "**/Generated/**"
safetyExemptions:
  - "// SAFETY:"
security:
  allowedHTTPHosts:
    - localhost
    - 127.0.0.1
status:
  stubThresholdLines: 50
  testCountDriftPercent: 10
  lastUpdatedStaleDays: 90
```

---

## Why build from source

The reusable workflow clones and builds quality-gate-swift from `main` on every CI run. This is intentional:

1. **Improvements propagate automatically.** When a new rule, heuristic fix, or checker is added to quality-gate-swift, every consuming project picks it up on its next CI run.
2. **No version pinning.** There are no release tags to bump, no dependency updates to remember, no stale binaries cached in CI.
3. **The bar only rises.** The quality standard applied to your project is always the latest. This matches the development-guidelines philosophy — clone fresh, don't vendor.

The build takes ~25 seconds. This is the cost of continuous improvement.

---

## For forked repos

If your project is a fork of someone else's repo, the quality gate workflow lives in your fork's `.github/workflows/` and only runs on your branches. The development-guidelines directory should be in `.git/info/exclude` (not `.gitignore`) to prevent leaking upstream.

See the Session Workflow (07_SESSION_WORKFLOW.md) for the forked repo setup checklist.
