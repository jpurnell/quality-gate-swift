# Scripts Guide — quality-gate-swift

This document is a narrative walkthrough of every script shipped with quality-gate-swift. Each section explains what the script does, when you would reach for it, and exactly how to run it.

---

## Overview

The `scripts/` directory contains six shell scripts that handle installation, git-hook setup, self-auditing, witness-list maintenance, corpus onboarding, and CI diffing. They are all Bash and designed to run on macOS. None of them require arguments beyond what is documented below — they figure out paths relative to the repository root.

| Script | Purpose | When to run |
|---|---|---|
| `install.sh` | Build and install the `quality-gate` binary globally | First-time setup, or after pulling updates |
| `install-hooks.sh` | Set up a git pre-push hook | Once per clone |
| `self-audit.sh` | Run quality-gate against its own source | Before merging a PR, or in CI |
| `regenerate-witnesses.sh` | Rebuild the protocol-witness allow-list from Xcode's symbol graphs | After Xcode/Swift updates (WWDC season) |
| `witness-diff-summary.sh` | Generate a Markdown summary comparing two witness files | During CI — called by the weekly GitHub Actions workflow |
| `onboard-corpus.sh` | Batch-configure Swift projects for IJS telemetry | When bringing projects into the quality-gate corpus |

---

## install.sh — Global Installer

**What it does.** Clones (or updates) the quality-gate-swift repository into `~/.quality-gate-swift`, builds a release binary, and copies it to `/usr/local/bin/quality-gate`. After it finishes, you can run `quality-gate` from any directory on your machine.

**When to use it.** Run this the first time you set up quality-gate on a new machine, or any time you want to update to the latest `main`.

**How to run it:**

```bash
# First-time install (from any checkout of quality-gate-swift):
./scripts/install.sh

# Update later:
cd ~/.quality-gate-swift && git pull && ./scripts/install.sh
```

**What happens step by step:**

1. If `~/.quality-gate-swift` already exists, the script fetches `origin/main` and hard-resets to it. Otherwise it clones the repo fresh.
2. It runs `swift build -c release` to produce an optimized binary.
3. It computes a SHA-256 hash of the binary and prints it — this is your integrity fingerprint.
4. It copies the binary to `/usr/local/bin/quality-gate`. If that directory is not writable, it uses `sudo`.
5. It prints a summary showing the installed path, the pinned commit, and the hash.

**Environment variable:** You can override the clone location by setting `QUALITY_GATE_HOME` before running the script. By default it uses `~/.quality-gate-swift`.

**Requires sudo:** Only if `/usr/local/bin` is not writable by your user. The script checks first and only escalates when necessary.

**Verify the install:**

```bash
quality-gate --help
```

---

## install-hooks.sh — Git Pre-Push Hook

**What it does.** Writes a git pre-push hook into the current repository's `.git/hooks/` directory. The hook runs `swift build` before every push and blocks the push if the build has errors.

**Why a pre-push hook instead of pre-commit?** The full quality-gate suite runs in CI. The pre-push hook is intentionally lightweight — it only checks that the project compiles — so that it finishes fast and avoids SSH timeouts during push operations.

**When to use it.** Run it once after cloning the repository. If you delete the hook and want it back, run it again.

**How to run it:**

```bash
./scripts/install-hooks.sh
```

**What happens:**

1. The script locates the `.git/hooks` directory relative to the repository root.
2. If a `pre-push` hook already exists, it exits with a message — it will not overwrite an existing hook. Remove the old one first if you want to reinstall.
3. It writes a new `pre-push` script that runs `swift build`, captures the output, and checks for `error:` in the log. If any errors are found, the push is blocked.
4. It makes the hook executable.

**To remove the hook:**

```bash
rm .git/hooks/pre-push
```

**Important:** The CLAUDE.md rules forbid using `--no-verify` to bypass this hook. If the hook blocks your push, fix the build error.

---

## self-audit.sh — Dogfooding quality-gate on Itself

**What it does.** Builds the quality-gate release binary and then runs it against quality-gate-swift's own source code, specifically the `unreachable` checker. This catches dead code across module boundaries that the in-process syntactic tests (`SelfAuditTests.swift`) cannot reach.

**When to use it.** Before merging a PR that adds, removes, or renames public API. The CI pipeline runs this automatically, but you can run it locally to catch issues early.

**How to run it:**

```bash
./scripts/self-audit.sh
```

**What happens:**

1. It builds the release binary with `swift build -c release`.
2. It removes the `.build/index-build` directory to force a fresh cross-module index. This ensures the unreachable-code checker sees the current state of every module, not a stale index.
3. It runs `quality-gate --check unreachable` against the repository.
4. If any error-severity unreachable findings are reported, the script exits non-zero.

**Exit codes:**

- `0` — no unreachable code found (clean).
- Non-zero — unreachable code detected; review the output and either delete the dead code or add it to an allow-list if it is intentionally unused (e.g., public API surface).

---

## regenerate-witnesses.sh — Protocol Witness Allow-List

**What it does.** Extracts protocol requirement names from Apple's framework symbol graphs (using `swift symbolgraph-extract`) and writes them into a generated Swift source file: `Sources/UnreachableCodeAuditor/WellKnownWitnesses+Generated.swift`. This file tells the unreachable-code auditor which method names are protocol witnesses — methods that exist to satisfy a protocol requirement and should not be flagged as dead code even if they have no direct call sites in the project.

**Why it exists.** When your type conforms to `Equatable`, the compiler synthesizes or you write `==`. That method has no explicit callers in your code, but it is not dead — it is a protocol witness. Without this allow-list, the unreachable-code auditor would report thousands of false positives. The script mines Apple's own symbol graphs to keep the list accurate and up to date.

**When to use it.** After installing a new Xcode or Swift toolchain — especially after WWDC when Apple ships new frameworks and protocols. A GitHub Actions cron job (`.github/workflows/regenerate-witnesses.yml`) also runs this every Monday and opens a PR if anything changed, so manual runs are rarely necessary.

**How to run it:**

```bash
./scripts/regenerate-witnesses.sh
```

**Requirements:** Xcode (for `xcrun swift symbolgraph-extract`) and `jq` (for parsing the JSON symbol graphs). Both are standard on a macOS development machine; `jq` can be installed with `brew install jq`.

**What happens step by step:**

1. It creates a temporary working directory (cleaned up on exit).
2. For each module in a hardcoded list (Swift, Foundation, SwiftUI, UIKit, AppKit, Combine, SwiftData, Observation, CoreData, CoreGraphics, OSLog, Charts, plus internal re-export modules like `_Concurrency` and `_StringProcessing`), it runs `swift symbolgraph-extract` to dump the module's public symbol graph as JSON.
3. It uses `jq` to walk every `.symbols.json` file and extract `(module, protocol, requirement)` tuples — one for each method or property that is a requirement of a protocol.
4. It sorts and deduplicates the tuples, then generates a Swift source file with every requirement name in a `Set<String>`, grouped under `// MARK: - Module.Protocol` comments.
5. It writes the file to `Sources/UnreachableCodeAuditor/WellKnownWitnesses+Generated.swift` and shows the `git diff --stat` so you can see what changed.

**The generated file header includes:** the date, the toolchain version, and coverage statistics (how many unique names across how many protocols).

**Modules list.** The `MODULES` array at the top of the script controls which frameworks are scanned. To add a new framework (for example, after Apple ships a new one), add its module name to that array and re-run. The script gracefully skips modules that are not available on the current SDK.

**CI integration.** The `regenerate-witnesses.yml` workflow runs this script weekly on GitHub Actions, then runs `witness-diff-summary.sh` to produce a human-readable PR body, and uses `peter-evans/create-pull-request` to open a PR if the generated file changed. The PR includes a reviewer checklist.

---

## witness-diff-summary.sh — Qualitative Diff Reporter

**What it does.** Compares two versions of the generated witness allow-list file and produces a Markdown summary describing what changed in human terms: which protocols were added, which were removed, which gained or lost requirements.

**When to use it.** You almost never run this by hand — it is called automatically by the `regenerate-witnesses.yml` GitHub Actions workflow to populate the body of the auto-generated PR. But you can run it manually to preview what a regeneration changed.

**How to run it:**

```bash
./scripts/witness-diff-summary.sh OLD.swift NEW.swift > summary.md
```

Where `OLD.swift` is the previous version of `WellKnownWitnesses+Generated.swift` and `NEW.swift` is the newly regenerated version.

**What the output contains:**

1. **Stats table** — protocol count and unique requirement-name count, before and after, with deltas.
2. **New protocols** — protocols that appear in the new file but not the old one. These are frameworks or protocols Apple added in the new toolchain.
3. **Removed protocols** — protocols that vanished entirely. Usually a rename or deprecation — the summary warns reviewers to sanity-check.
4. **Extended protocols** — existing protocols that gained new requirements (Apple added a new method to a protocol you may conform to).
5. **Trimmed protocols** — existing protocols that lost a requirement (Apple removed or renamed a method).
6. **Reviewer checklist** — a set of verification steps for the person reviewing the auto-PR.

If nothing changed at all, it says so and notes that the PR should not normally exist.

---

## onboard-corpus.sh — Batch Project Onboarding

**What it does.** Walks a list of Swift projects and configures each one for participation in the IJS (Integrated Judgement System) quality-gate telemetry corpus. For each project, it: clones or updates the development-guidelines repo, creates or updates a `.quality-gate.yml` config file, installs git hooks, copies a CLAUDE.md template if one doesn't exist, and optionally runs quality-gate to seed initial telemetry data.

**When to use it.** When you want to bring one or more Swift projects into the quality-gate ecosystem. This is the "Day 1" script for a project that has never been scanned before. It is also safe to re-run — it skips steps that are already complete.

**How to run it:**

```bash
# Onboard all known projects (the DEFAULT_PROJECTS list in the script):
./scripts/onboard-corpus.sh

# Preview what would happen without changing anything:
./scripts/onboard-corpus.sh --dry-run

# Config and hooks only, skip the quality-gate run (faster):
./scripts/onboard-corpus.sh --skip-run

# Onboard specific project(s) by path:
./scripts/onboard-corpus.sh /path/to/project1 /path/to/project2
```

**Flags:**

| Flag | Effect |
|---|---|
| `--dry-run` | Prints what would happen but makes no changes |
| `--skip-run` | Does config and hooks but skips the quality-gate analysis run |
| *(paths)* | Onboard only the listed projects instead of the default list |

**What happens for each project:**

1. **Development guidelines** — if the project already has a `development-guidelines/` directory with an `update.sh` script, it runs the updater. Otherwise it clones the development-guidelines repo into the project.
2. **Config file** — creates or appends to `.quality-gate.yml` with a `consistency:` section that points at the corpus path (`org-judgement-corpus`), sets a project ID, and configures a default consistency threshold and risk tier.
3. **Git hooks** — if the project has a `.git` directory and a `development-guidelines/scripts/install-hooks.sh`, it runs that installer.
4. **CLAUDE.md** — if the project has no `CLAUDE.md` but has a template in `development-guidelines/templates/CLAUDE.md`, it copies the template into place.
5. **Telemetry seeding** — if the project has a `Package.swift` and `--skip-run` was not passed, it runs quality-gate with a standard set of checkers (excluding test, doc-lint, disk-clean, memory-builder, unreachable, and status) to produce the first telemetry snapshot.

**The default project list** contains ~36 Swift projects and tools. The script automatically skips `quality-gate-swift` itself (it is in the `SKIP_PROJECTS` array). Projects without a `Package.swift` get "CONFIG ONLY" treatment — they receive the config file and hooks but no quality-gate run.

**Output.** The script prints a progress line for each project with a status (SUCCESS, PARTIAL, CONFIG ONLY, or SKIP) and elapsed time. At the end it prints a summary with totals and verification commands:

```
Verify:
  quality-gate dashboard --summary
  ls /path/to/org-judgement-corpus/telemetry/ | wc -l
```

**Prerequisites:**

- `quality-gate` must be installed and in your PATH (run `install.sh` first). If it is not found, the script warns you and falls back to `--skip-run` behavior.
- The corpus directory (`org-judgement-corpus`) must exist at its expected path.

---

## Quick Reference

**First-time setup on a new machine:**

```bash
cd quality-gate-swift
./scripts/install.sh          # build and install the binary
./scripts/install-hooks.sh    # set up the pre-push hook
```

**After an Xcode update:**

```bash
./scripts/regenerate-witnesses.sh
# Review the diff, commit if it looks right.
# (Or just wait for Monday's cron PR.)
```

**Before merging a PR:**

```bash
./scripts/self-audit.sh
```

**Onboarding your Swift projects:**

```bash
./scripts/onboard-corpus.sh --dry-run   # preview first
./scripts/onboard-corpus.sh             # then do it for real
```
