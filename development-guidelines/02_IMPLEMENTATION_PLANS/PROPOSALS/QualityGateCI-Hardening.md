# Design Proposal: Quality Gate CI Hardening

## 1. Problem

quality-gate-swift v1.0.0 shipped with 67 warnings (4 safety, 62 doc-coverage gaps, plus ~30 test-file deprecation warnings) that should have blocked release. The root cause is threefold:

1. **Incomplete CI checklist.** `quality-gate.yml` ran 6 of 14 available checkers. `ci.yml` ran none of the auditors. Neither ran `--check doc-coverage`.
2. **No single "release gate" job.** The two workflow files (`ci.yml` and `quality-gate.yml`) split responsibility without either being comprehensive. A developer looking at green CI assumed coverage was complete.
3. **Sources-only migration habit.** When the Diagnostic API was migrated, test files were skipped because the migration targeted `Sources/` only. CI didn't flag the test-file deprecation warnings because the build step doesn't use `-warnings-as-errors`.

These are process failures, not code failures. The tool itself catches everything — but CI wasn't configured to run the tool against itself completely.

## 2. Objective

Ensure that no commit can reach `main` with:
- Any quality-gate checker producing warnings or errors
- Any Swift compiler warning (including deprecations in test code)
- Any undocumented public API (doc-coverage < 100%)

## 3. Root Cause Analysis

### What happened

| Gap | Where | Impact |
|-----|-------|--------|
| `quality-gate.yml` missing 8 checkers | CI config | doc-coverage, logging, test-quality, context, accessibility, unreachable, doc-lint never ran |
| `ci.yml` has no auditor checks | CI config | Build + test passed but quality was unchecked |
| No `-warnings-as-errors` on `swift build` or `swift test` | CI config | Deprecation warnings in test files invisible |
| Manual quality-gate runs only checked working module | Process | Developer ran `--check safety` on SafetyAuditor, not full suite |
| No pre-push hook | Local tooling | Nothing stopped a push with outstanding warnings |

### Why it wasn't caught earlier

The project grew from 5 checkers to 17 over multiple sessions. Each new checker was tested individually but never added to the CI workflow. The `quality-gate.yml` was written when only safety, status, recursion, concurrency, and pointer-escape existed — and was never revisited.

## 4. Proposed Changes

### 4.1 — Single comprehensive quality-gate CI job (DONE)

**Status: Already implemented** in commit `083ef17`.

`quality-gate.yml` now runs all 14 checkers:
```yaml
.build/release/quality-gate
  --check safety
  --check doc-coverage
  --check status
  --check recursion
  --check concurrency
  --check pointer-escape
  --check logging
  --check test-quality
  --check context
  --check accessibility
  --check unreachable
  --check doc-lint
  --check swift-version
  --continue-on-failure
```

### 4.2 — Add `--check all` flag to quality-gate CLI

**Problem:** Every time a new checker is added, someone must remember to update the CI workflow YAML. This is the exact pattern that caused the v1.0.0 gap.

**Proposal:** Add a `--check all` argument to `QualityGateCLI` that dynamically discovers and runs every registered checker. CI uses `--check all` instead of enumerating checkers.

```yaml
# quality-gate.yml (after)
- name: Run quality gate against self
  run: .build/release/quality-gate --check all --continue-on-failure
```

**Implementation:** The CLI already has a `checkers` array. `--check all` iterates it. ~20 lines of code. This is the highest-leverage change — it makes the CI self-healing when new checkers are added.

### 4.3 — Warnings-as-errors in CI builds

**Problem:** Swift compiler deprecation warnings in test files were invisible because CI treats warnings as non-fatal.

**Proposal:** Add `-Xswiftc -warnings-as-errors` to the CI build and test steps:

```yaml
- name: Build
  run: swift build -Xswiftc -warnings-as-errors

- name: Test
  run: swift test -Xswiftc -warnings-as-errors
```

**Trade-off:** This will block CI on ANY compiler warning, including third-party dependency warnings we can't control. Mitigation: use `-Xswiftc -suppress-warnings` for specific dependency modules if needed, or scope the flag to project modules only.

**Alternative:** If `-warnings-as-errors` is too aggressive, add a CI step that counts warnings and fails if count > 0:
```yaml
- name: Check zero warnings
  run: |
    swift build 2>&1 | tee build.log
    if grep -c "warning:" build.log | grep -qv "^0$"; then
      echo "::error::Build produced warnings"
      exit 1
    fi
```

### 4.4 — Pre-commit / pre-push local hook

**Problem:** Developers push code without running the full quality gate locally.

**Proposal:** Ship a `scripts/install-hooks.sh` that installs a git pre-push hook running:

```bash
#!/bin/bash
swift build -c release && .build/release/quality-gate --check all --continue-on-failure
```

**Trade-off:** Pre-push hooks add latency (~15s for build + quality gate). Make it opt-in via the install script rather than mandatory. Document in CONTRIBUTING.md.

### 4.5 — Checklist gate in session workflow

**Problem:** The development-guidelines `07_SESSION_WORKFLOW.md` doesn't enforce running the full quality gate before marking a session complete.

**Proposal:** Add to the session workflow's "Before Push" phase:

```
## Before Push
- [ ] `quality-gate --check all --continue-on-failure` passes zero warnings
- [ ] `swift build 2>&1 | grep warning:` returns no output
- [ ] `swift test 2>&1 | grep warning:` returns no output
```

This is a process check, not tooling — but it's what would have caught this specific failure mode (human running partial checks and assuming completeness).

## 5. Implementation Priority

| # | Change | Effort | Impact | Status |
|---|--------|--------|--------|--------|
| 1 | Comprehensive CI workflow | Done | Critical | ✅ `083ef17` |
| 2 | `--check all` CLI flag | Small (20 LOC) | Critical | TODO |
| 3 | Warnings-as-errors in CI | Small (2 lines) | High | TODO |
| 4 | Pre-push hook script | Small | Medium | TODO |
| 5 | Session workflow checklist | Docs only | Medium | TODO |

Items 2 and 3 should be done immediately — they are the two remaining systemic fixes. Item 2 prevents recurrence of "forgot to add checker to YAML." Item 3 prevents recurrence of "deprecation warnings in test files."

## 6. Success Criteria

After implementing all items:
- Adding a new checker module requires zero CI configuration changes
- Any compiler warning (Sources/ or Tests/) blocks the CI pipeline
- Running `quality-gate --check all` locally reproduces exactly what CI will enforce
- The gap between "CI is green" and "quality is actually verified" is zero

## 7. Open Questions

1. **Should `--check all` exclude specific checkers by default?** Some checkers (like `unreachable`) require IndexStore and are slow. Option: `--check all --exclude unreachable` for fast local runs, full suite in CI.
2. **Should we add a `--strict` mode** that treats warnings as errors at the quality-gate level? Currently checkers return `.warning` status which doesn't fail the gate. `--strict` could promote all warnings to failures.
3. **Should the quality-gate self-test be a required status check on PRs?** Currently it runs on push to main — by the time it fails, the code is already merged.

---

**Date:** 2026-04-29
**Author:** Justin Purnell + Claude Opus 4.6
