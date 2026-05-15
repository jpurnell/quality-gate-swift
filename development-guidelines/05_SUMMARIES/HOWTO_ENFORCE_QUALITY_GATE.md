# How to Enforce quality-gate-swift in Your Project

A step-by-step guide for adopting quality-gate-swift and development-guidelines in a new or existing Swift project.

---

## Step 1: Check Prerequisites

**What to do:**

```bash
swift --version
git --version
```

**Why:** quality-gate-swift requires Swift 6.0+ and git. It runs on macOS 14+ and Linux.

**What to expect:** Swift version 6.0 or later. Any modern git version.

**Troubleshooting:** If your Swift version is below 6.0, update Xcode (macOS) or install a newer Swift toolchain from swift.org. On Linux, use swiftly or the official Swift tarballs.

---

## Step 2: Install quality-gate Globally

**What to do:**

```bash
git clone https://github.com/jpurnell/quality-gate-swift.git ~/.quality-gate-swift
cd ~/.quality-gate-swift
./scripts/install.sh
```

**Why:** This builds quality-gate from source and installs the binary to `/usr/local/bin` so it is available from any directory.

**What to expect:** The installer clones (or updates) the repo, builds a release binary, and copies it into place. Output ends with:

```
=== Installed ===
  Binary:  /usr/local/bin/quality-gate
  Version: main @ abc1234 (2026-05-14 ...)
  SHA256:  <hash>
```

Verify with:

```bash
quality-gate --help
```

You should see the full CLI help with all flags and checker IDs listed.

**Troubleshooting:**
- If the build fails with missing dependencies, run `swift package resolve` first.
- If `/usr/local/bin` requires sudo, the installer prompts automatically. Enter your password when asked.
- If `quality-gate --help` does not work, check that `/usr/local/bin` is on your `$PATH`.

---

## Step 3: Add development-guidelines to Your Project

**What to do:**

```bash
cd your-project
git clone https://github.com/jpurnell/development-guidelines.git development-guidelines
```

**Why:** The development-guidelines repo provides core coding rules, templates, hook installers, migration scripts, and session summary conventions that work hand-in-hand with quality-gate.

**What to expect:** A `development-guidelines/` directory containing:

- `00_CORE_RULES/` -- coding standards, TDD contract, enforcement architecture
- `02_IMPLEMENTATION_PLANS/` -- proposal and plan templates
- `05_SUMMARIES/` -- session summary storage (including this file)
- `scripts/` -- `install-hooks.sh` and `migrate.sh`
- `templates/` -- `CLAUDE.md` and `claude-settings.json`

**Troubleshooting:** If the directory already exists, `cd` into it and run `git pull` to get the latest version.

---

## Step 4: Install Git Hooks

**What to do:**

```bash
./development-guidelines/scripts/install-hooks.sh
```

**Why:** This installs a pre-commit hook and a pre-push hook. The pre-commit hook runs fast AST-based quality checks (~5-10 seconds) before every commit. The pre-push hook verifies `swift build` compiles clean before pushing.

**What to expect:**

```
=== Installing quality-gate git hooks ===

  Installing pre-commit hook...
  Installing pre-push hook...

Done. Hooks installed at .git/hooks
```

Verify:

```bash
ls .git/hooks/pre-commit .git/hooks/pre-push
```

Both files should exist and be executable.

**What the pre-commit hook runs:** It executes `quality-gate --check all` with the slow checks excluded (build, test, doc-lint, disk-clean, memory-builder, swift-version, unreachable). These slow checks run in CI instead.

**Troubleshooting:**
- If the script says "SKIPPED -- custom hook exists," you already have a hook at that path. Remove it first (`rm .git/hooks/pre-commit`) and re-run the installer.
- The hook is idempotent for managed hooks. Re-running updates them in place.
- To remove hooks later: `rm .git/hooks/pre-commit .git/hooks/pre-push`

---

## Step 5: Copy and Customize CLAUDE.md (Claude Code Users)

**What to do:**

```bash
cp development-guidelines/templates/CLAUDE.md ./CLAUDE.md
```

Open `CLAUDE.md` and replace `[PROJECT_NAME]` on the first line with your actual project name.

**Why:** Claude Code loads `CLAUDE.md` automatically at the start of every session. This file tells the agent about your quality-gate rules, forbidden patterns, TDD workflow, and how to run quality checks.

**What to expect:** A `CLAUDE.md` file at your project root containing sections on quality gate enforcement, zero-tolerance coding rules (no force unwraps, no `try!`, etc.), the TDD cycle, and references to the full rules in `development-guidelines/`.

**Troubleshooting:** If you already have a `CLAUDE.md`, merge the quality-gate sections into it rather than overwriting.

---

## Step 6: Copy Claude Code Settings (Optional, Claude Code Users)

**What to do:**

```bash
mkdir -p .claude
cp development-guidelines/templates/claude-settings.json .claude/settings.json
```

**Why:** This configures two things: a PostToolUse hook that runs `swift build` automatically every time a `.swift` file is edited, and a permission allowlist for common Swift and git commands so you get fewer confirmation prompts.

**What to expect:** After setup, every time Claude Code edits a Swift file, you will see "Building after Swift edit..." and the last few lines of build output. Build errors surface immediately, before the agent moves on.

**Troubleshooting:** If you already have `.claude/settings.json`, merge the `permissions` and `hooks` sections rather than replacing the file.

---

## Step 7: Set Up CI Workflow (GitHub-Hosted Projects)

**What to do:**

Create `.github/workflows/quality-gate.yml`:

```yaml
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

**Why:** The reusable workflow builds quality-gate from the latest `main` on every run. New rules and checkers propagate automatically with no version pins to maintain.

**What to expect:** On every push to `main` and every pull request, GitHub Actions will build quality-gate from source and run it against your project. The workflow accepts optional inputs:

- `checks` -- space-separated checker IDs (default: all defaults)
- `continue-on-failure` -- boolean, keep going after a failure
- `config` -- path to your `.quality-gate.yml`

Example with specific checks:

```yaml
jobs:
  quality-gate:
    uses: jpurnell/quality-gate-swift/.github/workflows/quality-gate-reusable.yml@main
    with:
      checks: "build safety concurrency"
      continue-on-failure: true
```

**Troubleshooting:** The reusable workflow runs on `macos-latest`. If you need Linux CI, build quality-gate directly in your own workflow instead.

---

## Step 8: Run quality-gate Locally (First Run)

**What to do:**

```bash
quality-gate --check all --strict --continue-on-failure --verbose
```

**Why:** This runs every checker, treats warnings as failures (`--strict`), continues past failures to show you everything at once, and prints progress as it goes.

**What to expect:** A list of all 25 checkers with PASSED, FAILED, or WARNING status. Each failing check shows diagnostics with file paths, line numbers, and descriptions. Fix all issues before your first commit.

For a lighter first pass that skips the slow checks:

```bash
quality-gate --check all --exclude build --exclude test --exclude doc-lint --strict --continue-on-failure
```

**Troubleshooting:**
- If quality-gate reports "No checkers enabled," verify `.quality-gate.yml` is valid YAML or remove it to use defaults.
- If a checker crashes, run it individually (`quality-gate --check safety --verbose`) to isolate the problem.

---

## Step 9: Test the Enforcement

**What to do:** Intentionally introduce a violation to confirm the hooks work.

```swift
// Add this line to any .swift file:
let x = someOptional!  // force unwrap
```

Try to commit:

```bash
git add -A && git commit -m "test enforcement"
```

**Why:** The pre-commit hook should catch the force unwrap via the safety auditor and block the commit.

**What to expect:**

```
Pre-commit: running quality gate...
...
[safety] FAILED
  MyFile.swift:42: Force unwrap detected — use guard let or if let
```

The commit is rejected. Remove the violation, stage again, and commit -- it should succeed.

**Troubleshooting:** If the commit goes through without checking, verify the hook is installed (`cat .git/hooks/pre-commit`) and executable (`ls -la .git/hooks/pre-commit`). The hook requires `quality-gate` to be on your `$PATH` or built locally at `.build/debug/quality-gate` or `.build/release/quality-gate`.

---

## Step 10: Updating quality-gate

**What to do:**

```bash
cd ~/.quality-gate-swift
git pull
./scripts/install.sh
```

**Why:** New rules, checkers, and bug fixes are picked up immediately by all projects that use the globally installed binary.

**What to expect:** The installer rebuilds and reinstalls. The SHA256 hash changes to reflect the new binary. All projects using quality-gate get the updated checks on their next commit.

---

## Step 11: Updating development-guidelines

**What to do:**

```bash
./development-guidelines/scripts/update.sh
```

That single command does everything: pulls the latest framework files from GitHub, preserves all your project-specific documents, reinstalls git hooks, and runs any structural migrations.

**Why:** `update.sh` is the go-forward update path. It replaces the old workflow of manually running `git pull`, `migrate.sh`, and `install-hooks.sh` separately. It syncs only *framework* files (core rules, scripts, templates, strategies) and never touches *project* files (summaries, roadmaps, implementation plans, library).

**What gets updated:**

| Directory/File | Updated? | Why |
|---|---|---|
| `00_CORE_RULES/` | Yes | Coding rules, enforcement docs, session workflow |
| `03_STRATEGIES_AND_FRAMEWORKS/` | Yes | Strategic frameworks |
| `scripts/` | Yes | Hook installer, migration, updater itself |
| `templates/` | Yes | CLAUDE.md template, settings template |
| `README.md`, `.version` | Yes | Top-level framework files |
| `01_ROADMAPS/` | **No** | Your project-specific roadmaps |
| `02_IMPLEMENTATION_PLANS/` | **No** | Your proposals, plans, ideas |
| `04_LIBRARY/` | **No** | Your reference materials |
| `05_SUMMARIES/` | **No** | Your session summaries |
| `CLAUDE.md` (project root) | **No** | Your customized project CLAUDE.md |
| `.quality-gate.yml` | **No** | Your quality gate config |

**What to expect:**

```
=== development-guidelines updater ===

Current version: 2026-05-01
Fetching latest from GitHub...
Upstream version: 2026-05-15

Syncing framework files...
  Updated 00_CORE_RULES/12_ENFORCEMENT.md
  Added   scripts/update.sh

Ensuring project directories exist...

Updating git hooks...
  Updating pre-commit hook (managed by quality-gate-swift)...
  Updating pre-push hook (managed by quality-gate-swift)...

==========================================
2 framework file(s) updated.

Review changes:
  git diff development-guidelines/

Run quality gate to check compliance:
  quality-gate --check all --strict --continue-on-failure
==========================================
```

After updating, run the quality gate to see if any new rules flag existing code. Fix issues before your next commit.

**Troubleshooting:**
- If `update.sh` fails with a network error, check that you can reach `github.com`.
- If it says "Already up to date," your framework files match the latest version.
- `update.sh` also installs `CLAUDE.md` from the template at your project root if you don't have one yet. If you already have a customized `CLAUDE.md`, it is never overwritten.
- For projects on very old versions of development-guidelines that predate `update.sh`, use the manual path: `cd development-guidelines && git pull`, then run `./development-guidelines/scripts/install-hooks.sh` and `./development-guidelines/scripts/migrate.sh`.

---

## Step 12: Configuring Checks Per Project

**What to do:**

Create `.quality-gate.yml` in your project root:

```yaml
excludePatterns:
  - "**/Generated/**"
  - "**/Vendor/**"

safetyExemptions:
  - "// SAFETY:"

enabledCheckers:
  - build
  - test
  - safety
  - recursion
  - concurrency
  - pointer-escape

concurrency:
  justificationKeyword: "Justification:"
  allowPreconcurrencyImports:
    - Alamofire

pointerEscape:
  allowedEscapeFunctions:
    - vDSP_fft_zip

security:
  secretPatterns: [password, secret, apiKey, token, credential, privateKey]
  allowedHTTPHosts: [localhost, 127.0.0.1]
```

**Why:** Not every project needs every checker, and some projects have legitimate exemptions. The config file lets you tune what runs, what gets excluded, and how specific checkers behave.

You can also override severity for specific rules:

```yaml
overrides:
  - ruleId: "force-unwrap"
    severity: warning
  - ruleId: "security.insecure-transport"
    severity: error
```

Per-checker configuration sections are available for: `concurrency`, `pointerEscape`, `security`, `status`, `logging`, `dependencyAudit`, `releaseReadiness`, `fpSafety`, `stochasticDeterminism`, `memoryLifecycle`, `mcpReadiness`, and `build`.

**What to expect:** quality-gate reads this file automatically on every run. If the file is missing or invalid, it falls back to defaults.

---

## Step 13: Emergency Bypass (Use Sparingly)

**What to do:**

```bash
QG_SKIP=1 git commit -m "emergency: fix production outage"
```

**Why:** Sometimes you need to commit immediately and fix quality issues in a follow-up. The `QG_SKIP=1` environment variable tells the pre-commit hook to allow the commit through.

**What to expect:**

```
WARNING: QUALITY GATE SKIPPED (QG_SKIP=1)
    You must follow up with a commit that passes the gate.
```

The commit proceeds. CI will still run the full quality gate on push, so violations are caught before merge.

**Important:** Never use `git commit --no-verify`. It skips ALL hooks, including pre-push, and leaves no trace that the gate was bypassed. `QG_SKIP=1` is the sanctioned escape hatch -- it prints a visible warning and still runs the pre-push hook.

---

## Quick Reference Card

| Command | What It Does |
|---------|-------------|
| `quality-gate` | Run all default checks |
| `quality-gate --check safety --check concurrency` | Run specific checks only |
| `quality-gate --check all --exclude build --exclude test` | Run everything except slow checks |
| `quality-gate --fix` | Auto-fix supported issues |
| `quality-gate --fix --dry-run` | Preview fixes without applying |
| `quality-gate --format json` | JSON output for scripting |
| `quality-gate --format sarif` | SARIF output for GitHub Code Scanning |
| `quality-gate --check status --bootstrap` | Generate initial project status docs |
| `quality-gate --strict` | Treat warnings as failures (exit 1) |
| `quality-gate --verbose` | Show detailed progress |
| `quality-gate --continue-on-failure` | Run all checks even if one fails |
| `./development-guidelines/scripts/install-hooks.sh` | Install or update git hooks |
| `./development-guidelines/scripts/migrate.sh` | Apply development-guidelines updates |
| `QG_SKIP=1 git commit -m "..."` | Emergency bypass (prints warning) |

---

## Inline Exemptions

When quality-gate flags something that is intentional, use an inline comment to suppress the diagnostic:

```swift
// SAFETY: Guaranteed non-nil by UIKit lifecycle
let view = optionalView!

// SECURITY: Test fixture, not a real credential
let testKey = "sk-test-only"

// Justification: Sendable compliance verified via code review
struct LegacyWrapper: @unchecked Sendable { ... }

// silent: error is logged by the caller
let _ = try? riskyOperation()
```

Each exemption type is recognized by its corresponding checker. The comment must appear on the line immediately preceding the flagged code or on the same line.
