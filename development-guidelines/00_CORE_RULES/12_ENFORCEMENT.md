# Mechanical Process Enforcement

**Purpose:** Make it impossible to commit code that fails quality standards. Documents are suggestions; hooks are guardrails.

> **The Problem:** We had 13 documents describing our development process.
> None of them prevented shipping 55 errors and 53 warnings.
> The AI assistant skipped the VERIFY step because it was a checklist item, not a gate.
>
> **The Solution:** Four enforcement layers that run automatically.
> If you can commit, the gate passed. If you can't, fix the issues first.

---

## Enforcement Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                  ENFORCEMENT LAYERS                          │
│                                                              │
│  Layer 1: Pre-Commit Hook (local, fast, ~5-10 seconds)       │
│  ├── safety, concurrency, recursion, pointer-escape          │
│  ├── doc-coverage, fp-safety, test-quality, logging          │
│  ├── release-readiness, accessibility, stochastic-determinism│
│  └── status, context, consistency, dependency-audit          │
│                                                              │
│  Layer 2: Pre-Push Hook (local, ~15 seconds)                 │
│  └── swift build — zero compiler errors                      │
│                                                              │
│  Layer 3: CI Workflow (remote, comprehensive)                │
│  ├── Everything in Layers 1-2, plus:                         │
│  ├── swift test — zero test failures                         │
│  ├── unreachable code detection (IndexStore)                 │
│  ├── doc-lint (DocC validation)                              │
│  └── swift-version compliance                                │
│                                                              │
│  Layer 4: CLAUDE.md (AI-specific)                            │
│  ├── Zero-tolerance coding rules loaded into every session   │
│  ├── Mandatory quality-gate command before marking complete  │
│  └── Forbidden bypass patterns                               │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Why This Split

- **Pre-commit** runs fast AST-only checks. These catch 90% of issues in seconds. They don't spawn `swift build` or `swift test` because those take 15-60+ seconds and would make commits painful.
- **Pre-push** verifies the build compiles. This catches import errors, type mismatches, and other compiler issues before they reach CI.
- **CI** runs everything including slow checks (unreachable code detection needs IndexStore from a prior build, doc-lint needs DocC tooling, tests need execution).
- **CLAUDE.md** catches process-level mistakes that hooks can't detect — like skipping the DESIGN phase or not writing a session summary.

---

## Installation

### Install quality-gate globally

```bash
# From the quality-gate-swift repo:
./scripts/install.sh

# Or clone and install:
git clone https://github.com/jpurnell/quality-gate-swift.git ~/.quality-gate-swift
cd ~/.quality-gate-swift && ./scripts/install.sh
```

This builds from `main` and copies to `/usr/local/bin/quality-gate`.

### Install git hooks (per-project)

```bash
./development-guidelines/scripts/install-hooks.sh
```

This installs both pre-commit and pre-push hooks. The script is idempotent — safe to re-run after updating development-guidelines.

### Update development-guidelines

```bash
./development-guidelines/scripts/update.sh
```

This pulls the latest framework files (core rules, scripts, templates) from GitHub while preserving all project-specific documents (summaries, roadmaps, checklists, plans). Run this at the start of each session or whenever you want the latest rules and auditors.

### Set up CLAUDE.md (per-project)

```bash
cp development-guidelines/templates/CLAUDE.md ./CLAUDE.md
# Edit CLAUDE.md: replace [PROJECT_NAME] with your project name
```

### Set up CI (per-project)

See [11_CI_QUALITY_GATE.md](11_CI_QUALITY_GATE.md).

---

## What Each Check Catches

| Check | Layer | Common Violations |
|-------|-------|-------------------|
| safety | Pre-commit | Force unwraps (`!`), `try!`, `as!`, `fatalError()` |
| concurrency | Pre-commit | Swift 6 strict concurrency violations, `@unchecked Sendable` without justification |
| recursion | Pre-commit | Self-calling inits, recursive computed properties |
| pointer-escape | Pre-commit | Pointer escaping `withUnsafe*` blocks |
| doc-coverage | Pre-commit | Public APIs missing `///` documentation |
| fp-safety | Pre-commit | Division without zero guard, unsafe IEEE 754 patterns |
| test-quality | Pre-commit | FP exact equality, weak assertions, unseeded random |
| logging | Pre-commit | `print()` in production, silent `try?`, empty catch blocks |
| release-readiness | Pre-commit | README markers (TODO, HACK), missing CHANGELOG entries |
| stochastic-determinism | Pre-commit | Non-reproducible randomness in test or production code |
| build | Pre-push | Compiler errors and warnings |
| test | CI | Test failures |
| unreachable | CI | Dead code (requires IndexStore) |
| doc-lint | CI | DocC documentation build errors |

---

## Escape Hatches

### QG_SKIP (pre-commit only)

```bash
QG_SKIP=1 git commit -m "emergency fix: ..."
```

This prints a prominent warning and allows the commit. Use only for genuine emergencies (infrastructure failure, CI outage, etc.). **You must follow up with a commit that passes the gate.**

**AI assistants must NEVER use `QG_SKIP` or `--no-verify`.**

### Adding Exemptions

For specific files or patterns, configure `.quality-gate.yml`:

```yaml
excludePatterns:
  - "**/Generated/**"
safetyExemptions:
  - "// SAFETY:"
```

---

## Troubleshooting

### "quality-gate not found"

Install globally: `cd ~/.quality-gate-swift && git pull && ./scripts/install.sh`

### Pre-commit hook is slow

The pre-commit hook should take 5-10 seconds. If it's slower:
1. Check that you're not accidentally running excluded checks
2. Verify the binary is release-built (`quality-gate` in PATH should be release)

### Hook was not installed

Run `./development-guidelines/scripts/install-hooks.sh` again. It's idempotent.

### Need to bypass for a specific commit

Use `QG_SKIP=1 git commit -m "..."`. Never use `--no-verify` — that skips ALL hooks including pre-push.

---

## Related Documents

- [Session Workflow](07_SESSION_WORKFLOW.md) — Context recovery and handover protocol
- [Coding Rules](01_CODING_RULES.md) — Full coding standards
- [CI Quality Gate](11_CI_QUALITY_GATE.md) — Reusable CI workflow
- [TDD Contract](09_TEST_DRIVEN_DEVELOPMENT.md) — Testing standards
