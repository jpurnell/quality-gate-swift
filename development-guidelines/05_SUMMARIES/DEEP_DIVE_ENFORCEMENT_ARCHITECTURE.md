# Enforcement Architecture: Technical Deep Dive

This document covers the WHY behind every design decision in quality-gate-swift's mechanical enforcement system. It is written for contributors, maintainers, and developers who want to understand, extend, or replicate this system in their own projects.

---

## 1. Architecture Overview

```
Developer workstation                              Remote
========================                           ========================

  git commit                                        git push / PR
      |                                                 |
      v                                                 v
 ┌─────────────────────┐                          ┌─────────────────────┐
 │  LAYER 1: PRE-COMMIT│                          │  LAYER 3: CI        │
 │  (~5-10 seconds)    │                          │  (full suite)       │
 │                     │                          │                     │
 │  quality-gate       │                          │  quality-gate       │
 │    --check all      │                          │    --check all      │
 │    --exclude build  │                          │    --strict         │
 │    --exclude test   │                          │                     │
 │    --exclude doc-   │                          │  Includes:          │
 │      lint           │                          │  - swift build      │
 │    --exclude disk-  │                          │  - swift test       │
 │      clean          │                          │  - unreachable      │
 │    --exclude memory-│                          │    (IndexStore)     │
 │      builder        │                          │  - doc-lint (DocC)  │
 │    --exclude swift- │                          │  - swift-version    │
 │      version        │                          │  - All AST checks   │
 │    --exclude        │                          │    from Layer 1     │
 │      unreachable    │                          │                     │
 │    --strict         │                          └─────────────────────┘
 │    --continue-on-   │
 │      failure        │
 └─────────┬───────────┘
           │ pass? ──no──> BLOCKED (fix issues)
           │ yes
           v
      commit created
           |
      git push
           |
           v
 ┌─────────────────────┐
 │  LAYER 2: PRE-PUSH  │
 │  (~15 seconds)      │
 │                     │
 │  swift build        │
 │  (zero errors)      │
 └─────────┬───────────┘
           │ pass? ──no──> BLOCKED (fix build)
           │ yes
           v
      pushed to remote ──────────> triggers Layer 3


 ┌─────────────────────────────────────────────────────────────────────┐
 │  LAYER 4: CLAUDE.md (AI-Specific, loaded at session start)         │
 │                                                                     │
 │  - Zero-tolerance coding rules (inline, not references)             │
 │  - Mandatory quality-gate command before marking work complete       │
 │  - Forbidden: --no-verify, QG_SKIP                                  │
 │  - Process rules: TDD cycle, design proposals, session protocol     │
 │                                                                     │
 │  Scope: catches process-level drift that hooks cannot detect         │
 │  (e.g., skipping DESIGN phase, not writing tests first)             │
 └─────────────────────────────────────────────────────────────────────┘
```

### When Each Layer Runs

| Layer | Trigger | Duration | Scope | Authority |
|-------|---------|----------|-------|-----------|
| Pre-commit | `git commit` | 5-10s | AST-only checks | Local gate |
| Pre-push | `git push` | ~15s | `swift build` | Local gate |
| CI | push/PR to remote | 2-5 min | Full suite | Final authority |
| CLAUDE.md | AI session start | N/A | Process rules | Advisory (AI only) |

CI is the authority. Pre-commit is the fast local approximation. If pre-commit and CI disagree, CI wins. This is by design — pre-commit is optimized for speed, not completeness.

---

## 2. Check Classification: Pre-Commit vs CI

### Why These Checks Are in Pre-Commit

Pre-commit checks must satisfy three constraints:

1. **Fast.** Under 10 seconds total. Developers will bypass a slow hook.
2. **No process spawning.** No `swift build`, no `swift test`, no DocC. Process spawning adds startup overhead and can fail for reasons unrelated to code quality (missing toolchain, disk space, etc.).
3. **Deterministic.** Same input, same output, every time. No dependency on build artifacts, IndexStore, or network state.

All pre-commit checks are pure SwiftSyntax AST analysis. They parse Swift source files into syntax trees and walk them looking for patterns. No compilation, no type checking, no linking.

### Why These Checks Are CI-Only

| Check | Why CI-Only |
|-------|-------------|
| `build` | Spawns `swift build`. Takes 15-60+ seconds. Requires full toolchain. |
| `test` | Spawns `swift test`. Takes 30-120+ seconds. Requires compilation. |
| `doc-lint` | Spawns DocC. Requires compilation and DocC tooling. |
| `unreachable` | Requires IndexStore from a prior `swift build` with `-index-store-path`. Cannot run on source alone. |
| `swift-version` | Checks Swift version compatibility. Requires `swift --version`. Environment-specific. |
| `disk-clean` | Has side effects (removes build artifacts). Not appropriate for pre-commit. |
| `memory-builder` | Generates memory files. Side effect, not a gate. |

### Complete Check Assignment Table

| Check ID | Pre-Commit | Pre-Push | CI | What It Catches |
|----------|:----------:|:--------:|:--:|-----------------|
| safety | X | | X | Force unwraps, `try!`, `as!`, `fatalError()` |
| concurrency | X | | X | Swift 6 strict concurrency, `@unchecked Sendable` |
| recursion | X | | X | Self-calling inits, recursive properties |
| pointer-escape | X | | X | Pointers escaping `withUnsafe*` blocks |
| doc-coverage | X | | X | Public APIs missing `///` documentation |
| fp-safety | X | | X | Division without zero guard, IEEE 754 patterns |
| test-quality | X | | X | FP exact equality, weak assertions, unseeded random |
| logging | X | | X | `print()` in production, silent `try?`, empty catch |
| release-readiness | X | | X | TODO/HACK markers, missing CHANGELOG |
| stochastic-determinism | X | | X | Non-reproducible randomness |
| accessibility | X | | X | SwiftUI accessibility violations |
| status | X | | X | Master Plan vs code state drift |
| context | X | | X | Ethical context (consent, analytics, surveillance) |
| consistency | X | | X | Institutional consistency scoring |
| dependency-audit | X | | X | Dependency graph issues |
| build | | X | X | Compiler errors and warnings |
| test | | | X | Test failures |
| doc-lint | | | X | DocC validation errors |
| unreachable | | | X | Dead code (requires IndexStore) |
| swift-version | | | X | Toolchain version compliance |
| disk-clean | | | X | Build artifact cleanup (side effect) |
| memory-builder | | | X | Memory file generation (side effect) |

---

## 3. Distribution Model: Global Install over SPM Plugin

### The Problem with SPM Plugins

quality-gate-swift depends on SwiftSyntax. SwiftSyntax is a large dependency: its build artifacts add roughly 100MB per project. If quality-gate-swift were distributed as an SPM command plugin, every consuming project would:

1. Pull SwiftSyntax into its own dependency graph
2. Build SwiftSyntax as part of its own build
3. Store ~100MB of SwiftSyntax artifacts in its own `.build/` directory
4. Experience increased `swift package resolve` times
5. Risk SwiftSyntax version conflicts with other dependencies

For a project that wants to use quality-gate-swift for analysis (not as a library dependency), this is pure overhead.

### How the Industry Handles This

SwiftLint, swift-format, and similar tools use the same distribution model we chose:

- **Global binary.** Install once, use everywhere. The binary lives in `/usr/local/bin/` or `~/.local/bin/`.
- **No per-project dependency.** The consuming project's `Package.swift` never mentions the tool.
- **Version controlled by the developer.** Update when you want by re-running the installer.

quality-gate-swift follows this model exactly.

### The `scripts/install.sh` Design

```
install.sh flow:
  1. Clone (or git pull) quality-gate-swift to ~/.quality-gate-swift
  2. Checkout main branch
  3. swift build -c release
  4. Copy .build/release/quality-gate to /usr/local/bin/quality-gate
  5. Print SHA256 of installed binary for verification
```

Key decisions:

- **Always builds from `main`.** No release tags, no version pins. The latest `main` IS the release. This matches the CI model where the reusable workflow also builds from `main`.
- **Release build.** The installed binary is optimized. Debug builds of SwiftSyntax-based tools are noticeably slower.
- **SHA256 output.** Printed for auditability. If a developer suspects their binary is stale, they can compare hashes.
- **`QUALITY_GATE_HOME` override.** For developers who want the clone somewhere other than `~/.quality-gate-swift`.

---

## 4. Hook Design Decisions

### Idempotent Installation

The `install-hooks.sh` script uses marker-based detection:

```bash
MARKER="# quality-gate-swift managed hook"
```

On install, it checks whether the existing hook file's first three lines contain this marker. If they do, the hook is a managed hook and can be safely overwritten. If they don't, the script assumes the hook is a custom user hook and refuses to overwrite it.

This makes `install-hooks.sh` safe to re-run at any time. Updating development-guidelines and re-running the script will update managed hooks without destroying custom hooks. The migration script (`migrate.sh`) calls `install-hooks.sh` automatically when hooks are missing.

### Binary Discovery Chain

The pre-commit hook finds `quality-gate` through a priority chain:

```
1. PATH lookup (command -v quality-gate)  — global install
2. .build/debug/quality-gate              — local debug build
3. .build/release/quality-gate            — local release build
```

PATH comes first because the global install is the intended distribution model. The `.build/` fallbacks exist for quality-gate-swift's own repository, where the developer may be iterating on the tool itself and wants to test their local build.

### Why Not `--no-verify` Based Enforcement

Some teams enforce quality by adding a `--no-verify` prohibition to their code review checklist. This does not work for two reasons:

1. `--no-verify` skips ALL hooks, not just specific ones. If you have a pre-commit hook for quality-gate AND a pre-push hook for build verification, `--no-verify` bypasses both.
2. There is no way to detect `--no-verify` usage after the fact. The commit is created. The history shows a normal commit. The bypass is invisible.

`QG_SKIP=1` is better because:
- It only affects the quality-gate check, not other hooks
- The hook prints a visible warning (`QUALITY GATE SKIPPED`)
- It is an environment variable, which can be detected by wrapper scripts or logged

### QG_SKIP: The Escape Hatch

`QG_SKIP=1 git commit -m "emergency fix: ..."` bypasses the pre-commit quality gate while leaving the pre-push build check intact.

Why it must exist:

- **The quality-gate binary could be broken.** If a bad commit to quality-gate-swift's `main` branch produces a broken binary, every project using the global install is blocked from committing. `QG_SKIP` is the release valve.
- **Infrastructure emergencies.** Filesystem issues, permission problems, SwiftSyntax crashes on edge-case files — things that are not the developer's fault.
- **Atomic multi-commit operations.** Sometimes a refactor requires an intermediate commit that legitimately fails the gate (e.g., renaming a public API — the doc-coverage check will fail until the new name is documented in a subsequent commit).

Why AI assistants cannot use it:

- AI assistants have no infrastructure emergencies. Their environment is controlled.
- If the gate fails, the AI's job is to fix the code, not bypass the gate.
- CLAUDE.md explicitly prohibits both `QG_SKIP` and `--no-verify`. This is a hard rule, not a suggestion.

---

## 5. CLAUDE.md as AI-Specific Enforcement

### Why Inline Rules Beat Document References

The 55-error incident happened because the AI assistant was given 13 documents to follow. It acknowledged them at session start and then ignored them during implementation. The documents were thorough, well-organized, and irrelevant — because they were not in the AI's immediate working context when decisions were being made.

CLAUDE.md solves this by putting rules where the AI cannot ignore them: in the file that is loaded into context at session start and stays there. Every rule is self-contained. No "see document X for details."

The old approach:
```
### Testing
See development-guidelines/00_CORE_RULES/TESTING.md for testing standards.
```

The new approach:
```
### Testing
- Stochastic tests: always use seeded RNG, never implicit `.random()`
- Assertions: use specific expected values, not `!= 0` or `!= nil`
- Tests must be deterministic and reproducible
```

The second version costs more tokens. It also works.

### Why Under 150 Lines

AI assistants have finite context windows. Long CLAUDE.md files get compacted or summarized during long sessions. A 150-line file fits comfortably within the working context budget. Every line earns its place.

Rules that do not fit in 150 lines belong in the development-guidelines documents, which are reference material. CLAUDE.md is not reference material. It is the set of rules that must be active in the AI's context during every edit.

### What Belongs in CLAUDE.md vs development-guidelines

| Belongs in CLAUDE.md | Belongs in development-guidelines |
|----------------------|-----------------------------------|
| Concrete rules the AI must follow on every edit | Rationale and history behind the rules |
| Quality gate commands to run | How to configure the quality gate |
| Forbidden patterns (force unwrap, etc.) | Why those patterns are dangerous |
| TDD cycle summary (one line) | Full TDD contract with examples |
| Architecture overview (module list) | Detailed architecture documentation |
| Build feedback hook description | Hook implementation details |

### Template Design for Cross-Project Consistency

The `templates/CLAUDE.md` file in development-guidelines provides a standardized starting point. Projects copy it to their root and replace `[PROJECT_NAME]` with their project name.

The template includes:
- Quality gate enforcement section (identical across all projects)
- Zero-tolerance coding rules (identical across all projects)
- Development workflow summary (identical across all projects)
- Build feedback hook reference (identical across all projects)
- Architecture section placeholder (project-specific)

Consistency matters because the AI assistant works across multiple projects. If the CLAUDE.md format varies between projects, the AI must re-learn the structure each time. A consistent template means the AI always knows where to find the rules.

The `templates/claude-settings.json` file provides a matching Claude Code settings configuration with pre-approved permissions and a PostToolUse hook that runs `swift build` after every `.swift` file edit.

---

## 6. Cross-Project Propagation

### development-guidelines as the Vehicle

development-guidelines is a template repository that gets cloned into each project's `development-guidelines/` directory. It contains:

```
development-guidelines/
  00_CORE_RULES/          # Standards documents (13+ files)
  01_ROADMAPS/            # Project roadmaps
  02_IMPLEMENTATION_PLANS/ # Design proposals and plans
  03_STRATEGIES_AND_FRAMEWORKS/
  04_IMPLEMENTATION_CHECKLISTS/
  04_LIBRARY/
  05_SUMMARIES/           # Session summaries, blog posts
  06_BACKUP_FILES/
  scripts/
    install-hooks.sh      # Git hook installer
    migrate.sh            # Non-destructive migration
  templates/
    CLAUDE.md             # AI enforcement template
    claude-settings.json  # Claude Code settings template
  README.md
```

When a project adopts or updates its guidelines, the enforcement stack comes along automatically.

### install-hooks.sh: Ships with Guidelines

The hook installer lives inside development-guidelines, not in the consuming project. This means:

- Updating development-guidelines automatically brings the latest hook scripts
- The hooks themselves are defined inline in the installer (heredoc), not as separate files
- The installer is the single source of truth for hook content

Running `./development-guidelines/scripts/install-hooks.sh` installs both the pre-commit and pre-push hooks. The script:

1. Finds the `.git/hooks/` directory via `git rev-parse --show-toplevel`
2. For each hook, checks if a managed hook exists (marker-based)
3. If managed or absent, writes the new hook content
4. If a custom (non-managed) hook exists, prints a warning and skips
5. Sets execute permissions

### Migration Pathway

The `migrate.sh` script handles structural updates when development-guidelines evolves:

- **Version marker.** A `.version` file tracks the migration state. If the installed version matches the current version, migration is a no-op.
- **Non-destructive.** `ensure_dir()` creates missing directories. `copy_if_missing()` copies new template files only if they don't already exist. Nothing is overwritten.
- **Hook installation.** If hooks are missing, migration installs them automatically.
- **CLAUDE.md seeding.** If no CLAUDE.md exists at the project root, migration copies the template.

This design means a project can update its development-guidelines (git pull, or re-clone) and run `migrate.sh` to pick up structural changes without losing any project-specific content.

### Always-Latest Model

Both the quality-gate binary (via `install.sh`) and the CI workflow (via `uses: ...@main`) follow an always-latest model:

- No version tags to bump
- No dependency update PRs to review
- No "please update your tooling" announcements
- The quality bar can only go up, never down

The trade-off: a bad commit to quality-gate-swift's `main` temporarily affects all projects. This is mitigated by quality-gate-swift dogfooding itself — the same pre-commit and CI checks that protect consuming projects also protect quality-gate-swift's own `main` branch.

---

## 7. Tradeoffs Accepted

### Pre-commit adds 5-10 seconds to every commit

This is the cost of enforcement. The alternative — no enforcement — costs far more in cleanup time. The 55-error incident required a full session of remediation work. Ten seconds per commit would have caught each issue at the moment of introduction.

We optimized by excluding slow checks (build, test, doc-lint, unreachable). The remaining AST checks are fast because SwiftSyntax parsing is fast. If the pre-commit hook ever exceeds 15 seconds, that is a bug to investigate (probably a new check that accidentally spawns a process).

### QG_SKIP exists

Every enforcement system needs an escape hatch. A system with no escape hatch will be circumvented in more destructive ways (deleting the hook file, using `--no-verify`, disabling Git hooks globally). `QG_SKIP` is a controlled, visible bypass that preserves the hook infrastructure and prints a warning.

The key constraint: AI assistants cannot use it. Only human developers can invoke `QG_SKIP`, and only for documented emergencies.

### CI and pre-commit can diverge

Pre-commit runs a subset of checks. CI runs all checks. This means code can pass pre-commit and fail CI. This is acceptable because:

- CI is the authority. Pre-commit is the fast approximation.
- The checks that CI catches but pre-commit misses (build failures, test failures, unreachable code) are things the developer likely already knows about from their edit-build-test loop.
- The checks that pre-commit catches are the "silent" violations that developers DON'T know about — the floating-point equalities, the weak assertions, the missing docs.

If divergence causes pain (developers are surprised by CI failures that pre-commit didn't catch), the fix is to add more information to the pre-commit output, not to make pre-commit slower.

### Global install means all projects share one binary version

This is a feature, not a bug. When we fix a false positive in the safety checker, every project benefits immediately. When we add a new heuristic to the test-quality checker, every project is checked by it.

The risk is that a regression in the quality-gate binary breaks all projects simultaneously. This is mitigated by:

1. quality-gate-swift's own pre-commit and CI enforcement
2. 850+ tests that run on every change
3. `QG_SKIP` as an emergency release valve
4. Developers can pin to a specific commit by checking out that commit in `~/.quality-gate-swift` instead of pulling `main`

---

## 8. Alternatives Rejected

### SPM Command Plugin

Swift Package Manager supports command plugins that can run tools as part of the build process. We rejected this approach because:

- **SwiftSyntax dependency tax.** Every consuming project would need to resolve and build SwiftSyntax (~100MB build artifacts). For projects that don't otherwise use SwiftSyntax, this is pure waste.
- **Version coupling.** SwiftSyntax versions must match the Swift toolchain. An SPM plugin pins a specific SwiftSyntax version in the consumer's dependency graph, which can conflict with other dependencies.
- **Build time impact.** The first `swift build` in a clean checkout would include building the entire quality-gate tool, adding minutes to the build.
- **No pre-commit integration.** SPM plugins run during `swift build`, not during `git commit`. The pre-commit hook workflow is not possible with an SPM plugin.

### SPM Binary Target

SPM supports binary targets (`.artifactbundle`) that distribute pre-built binaries. We rejected this because:

- **Release pipeline overhead.** Every quality-gate update would require building release binaries for all platforms (macOS arm64, macOS x86_64, Linux), packaging them, uploading to a release, and updating the binary target URL.
- **Platform matrix.** quality-gate-swift must support at least macOS arm64 and macOS x86_64. Each platform needs its own binary.
- **Still an SPM dependency.** The consumer's `Package.swift` still references quality-gate, and version management is still required.

### Homebrew Tap

A Homebrew formula (`brew install jpurnell/tap/quality-gate`) would provide a clean install experience. We rejected this because:

- **Setup overhead.** Creating and maintaining a Homebrew tap requires a separate repository, formula definition, and CI pipeline for bottling.
- **macOS only.** Homebrew is primarily macOS. Our CI runs on macOS, but the distribution model should not exclude Linux in principle.
- **Unnecessary abstraction.** `git clone && ./scripts/install.sh` is simple enough. Adding Homebrew is overhead without meaningful benefit for a tool used across a single developer's projects.

If quality-gate-swift ever needs broader distribution (open-source community adoption), a Homebrew tap would become worth the setup cost. For 24+ projects under one developer, the global install script is sufficient.

### Claude Code PreToolUse Hook

Claude Code supports a `PreToolUse` hook that runs before every tool invocation. We initially attempted to use this to run `swift test` before every Bash command:

```json
{
  "PreToolUse": [{
    "matcher": "Bash",
    "hooks": [{
      "type": "command",
      "command": "swift test 2>&1 | tail -5"
    }]
  }]
}
```

This was immediately broken. The hook ran `swift test` on EVERY Bash command — including `ls`, `git status`, `find`, and other read-only commands. This added 30-60 seconds to every tool call and made the AI assistant unusable.

The correct approach is a `PostToolUse` hook scoped to `Edit|Write` that runs `swift build` (not `swift test`) only when a `.swift` file is modified. This is what the `templates/claude-settings.json` file provides. The build-on-edit hook gives fast feedback (compilation errors appear immediately) without the overhead of running the full test suite on every edit.

The quality gate itself runs at commit time (pre-commit hook) and at completion (CLAUDE.md's mandatory command), not on every edit.

---

## Summary

The enforcement architecture is four layers with complementary strengths:

- **Pre-commit** catches 90% of issues in 5-10 seconds using AST analysis
- **Pre-push** catches compilation errors before they reach the remote
- **CI** is the comprehensive, authoritative gate
- **CLAUDE.md** catches process-level drift that hooks cannot detect

The distribution model avoids per-project dependency overhead by installing globally. The propagation model uses development-guidelines as the vehicle, with idempotent scripts that can be re-run safely. The escape hatch (`QG_SKIP`) exists for emergencies but is forbidden for AI assistants.

Every design decision optimizes for one outcome: making it harder to ship bad code than to write good code.
