# quality-gate-swift — Overview & Case Study

*A modular, AST-powered quality gate for Swift projects. This document is both a plain-language introduction and a structured source document — it is written to be read by a person in five minutes, or ingested by an LLM (NotebookLM, Claude, etc.) as reference material about how the tool works and how it fits into product development.*

---

## 1. What it is

**quality-gate-swift** is a static-analysis tool that enforces correctness, safety, concurrency, documentation, and security rules on Swift codebases — automatically, on every commit and every push.

It is not a linter that nags about whitespace. It is a **gate**: code that violates a correctness or safety rule does not get committed. Whitespace and style rules exist too, but they are *advisory* by design — the gate blocks on things that can crash a shipping app, not on formatting.

Three numbers frame it:

- **42 checkers**, each an independent Swift package module with its own tests and documentation.
- **2,871 tests** covering the checkers themselves — the tool is held to the standard it enforces.
- **Zero regex.** Every rule walks the Swift **AST** (abstract syntax tree) via Apple's SwiftSyntax. It understands scope, type context, and control flow — so it catches real defects and produces very few false positives.

### The core idea

Most quality problems in Swift aren't typos — they're *structural*: a force-unwrap that will crash on the one nil you didn't expect, an `async` stream whose cancellation path was never specified, a pointer that escapes the block that owned it, a division with no zero-guard. These are invisible to regex and often invisible to code review. They are visible to a tool that reads the code the way the compiler does.

quality-gate-swift reads the tree, not the text.

---

## 2. How it works

### AST-first analysis

Each checker is a SwiftSyntax *visitor*. Instead of matching text patterns, it walks the parsed structure of the code. A regex looking for a force-unwrap (`!`) can't tell the difference between `value!` and `value != nil` and a `!` inside a string literal. An AST visitor knows exactly which is which — and knows the enclosing function, the surrounding control flow, and whether a `guard` already made the unwrap safe.

This is why false positives are rare enough that the tool can *block* rather than merely *warn*.

### Modular architecture

Every checker is a separate SPM target — `SafetyAuditor`, `ConcurrencyAuditor`, `RecursionAuditor`, and so on. A project can depend on only the checkers it wants, or run the whole suite through the umbrella CLI. Each module ships its own DocC documentation catalog.

### Structured output

The tool emits results in four formats so it plugs into whatever consumes them:

| Format | Consumer |
|--------|----------|
| `terminal` | A developer at the command line |
| `json` | Scripts, dashboards, telemetry |
| `sarif` | **GitHub Code Scanning** — findings appear inline on pull requests |
| `xcode` | Xcode Build Phase — findings appear as build warnings/errors in the IDE |

### Auto-fix

Checkers that conform to `FixableChecker` can repair issues automatically with `--fix` (and preview with `--fix --dry-run`). Fixes are round-trip-tested: apply the fix, re-parse, confirm the rule now stays silent.

### The checker families

| Family | Examples | What they catch |
|--------|----------|-----------------|
| **Correctness** | recursion, pointer-escape, concurrency, fp-safety, memory-lifecycle, unreachable, complexity | Crashes, races, dead code, unsafe pointers, runaway complexity |
| **Safety & Security** | safety, stochastic/temporal-determinism, hig-auditor | Force unwraps, `try!`, `fatalError`, OWASP Mobile Top 10, nondeterminism |
| **Code Hygiene** | logging, test-quality, accessibility, context | `print()` in production, silent catches, weak tests, a11y gaps |
| **Documentation** | doc-coverage, doc-lint | Undocumented public APIs, broken DocC |
| **Project Health** | build, test, status, dependency-audit, release-readiness | Build/test failures, doc drift, dependency sync, hallucinated imports |

---

## 3. What it brings to a project

- **Defects caught before they ship.** The rules target the class of bug that survives code review and TDD — the ones that only appear under load, under cancellation, or on the one edge case nobody tested.
- **A gate, not a suggestion.** Because false positives are rare, the tool can enforce. Bad code doesn't merge. There is no backlog of ignored warnings.
- **No override culture.** Exemptions exist (`// SAFETY:`, `// Justification:`), but every one is a single inline comment that states *why* — recorded, not silent. You can see every place the rules were consciously relaxed.
- **It travels with the code.** Pre-commit hook, pre-push hook, CI via SARIF, Xcode build phase — the same canonical run path in every environment, so "passes on my machine" and "passes in CI" mean the same thing.
- **It dogfoods itself.** quality-gate-swift runs its own 42 checkers on every push. The tool is subject to its own gate.

---

## 4. Case study: Harbor

**Harbor** is a biofeedback headset product — a multi-package Swift workspace (HarborKit, HarborUI, HarborWatchKit, plus the BioFeedbackKit/EdgeSDK sensor stack) that processes real-time RR-interval data from the headset. It is exactly the kind of codebase quality-gate-swift is built for: concurrent, async, sensor-driven, and shipping to real users.

Harbor is not a hypothetical. It is where several of the tool's most valuable checkers were *born* — because a real bug got through everything else first.

### The bug that TDD didn't catch

A Harbor session could be ended two ways: it could **complete** on its own, or the user could **stop** it. These are semantically different — a stopped session should not be recorded as completed.

The session loop consumed sensor data with `for try await` over an `AsyncThrowingStream`. The author reasoned about two exit paths: the stream finishes (completed), or it throws (error). But there is a **third** path: when the task is *cancelled*, a `for try await` on an `AsyncThrowingStream` **ends quietly** — the iterator simply returns `nil`. It does not throw `CancellationError`.

So a user-initiated **stop** fell through to the post-loop `session.markCompleted()` — and was silently recorded as a *completed* session.

This defect:

- survived **Design-First TDD**,
- survived **3+ consecutive green quality-gate cycles**, and
- only surfaced when parallel package gates accidentally stress-loaded the scheduler enough to make the race reliable.

It was invisible to code review because the code *looked* correct. It was invisible to the test suite because the suite passed — twice — on a byte-identical package. It was a scheduler-dependent race, not a code error you could point at.

### Three checkers came out of it

Rather than fix the one bug and move on, the failure became the specification for three new detectors (the "Concurrency Gate Tightening" work):

1. **`cancellation-checkpoint-after-loop`** — an AST rule that flags a `for await` / `for try await` loop, inside a function that already treats cancellation as meaningful, that is followed by exit-reason-dependent code with **no** post-loop cancellation check. It requires knowing the enclosing function's boundary and walking the loop's following statements in control-flow order — which is why it's AST-based, not regex. This rule catches the exact Harbor shape *before* it can ship.

2. **Test-outcome flip detector** — the gate runs the suite on every commit but is otherwise memoryless. This detector persists a per-package pass/fail roster and flags any test whose outcome **flipped while the package fingerprint was unchanged**. A flip on byte-identical source is a *definitive* signal of a scheduler-dependent race — precisely the Harbor class. It names both commits so the regression window is bounded.

3. **Timing-tagged stress mode** — tests carrying a `// TIMING:` marker are self-identifying race candidates. On demand, the runner re-runs *only* those tests N times under CPU contention and flags any that aren't unanimous across identical runs. This *provokes* the race deliberately, instead of waiting for the scheduler to expose it by accident — which is how the original bug was found in the first place.

### The other Harbor lesson: precision at scale

Harbor also stress-tested the tool's **false-positive discipline**. An early run of the unreachable-code checker against Harbor emitted **~1,064** `unreachable.cross_module` findings — almost all from a vendored SDK the team didn't own and couldn't change. A gate that cries wolf 1,064 times is a gate people learn to ignore.

The fix tightened the checker (correct handling of vendored code, and skipping the cross-module pass on a stale index rather than emitting wrong-line findings), dropping Harbor's unreachable findings **from 1,064 to 0**. The same discipline later collapsed a 14,000-row duplication false-positive storm down to 11 genuine findings.

**The lesson quality-gate-swift takes from Harbor:** a quality gate is only as valuable as it is trusted, and it is only trusted if nearly every finding is real. Precision isn't a nicety — it's the whole product.

---

## 5. How it integrates with product development

quality-gate-swift is designed to sit inside a development workflow, not beside it.

### The TDD cycle it enforces

```
DESIGN → RED (failing test) → GREEN (minimum to pass) → REFACTOR → DOCUMENT → VERIFY
```

Non-trivial features start with a written design proposal. Tests come before implementation. The gate runs at VERIFY — and because it runs the build and the test suite too, "verified" means the whole thing is green, not just that the code compiles.

### Where it runs

- **Pre-commit hook** — blocks a commit that introduces a violation. No `--no-verify`, no skip flags; the rule is to fix the root cause, never to silence the finding.
- **Pre-push hook** — a fuller pass before code leaves the machine.
- **CI (GitHub Actions)** — emits SARIF; findings show up inline on the pull request via GitHub Code Scanning. One canonical run path shared with the local hooks, with parity proven byte-for-byte.
- **Xcode Build Phase** — findings surface as native build warnings/errors while you code.

### The dashboard and telemetry

Runs emit structured telemetry to a corpus. A macOS dashboard reads it and shows per-project gate status — with an honest distinction between green confirmed by a *full* run and green assembled from partial re-runs. The point is that the health signal is trustworthy: you can tell at a glance whether a project is genuinely passing or only partially checked.

### The workflow contract, in one sentence

**Write a failing test, make it pass with the minimum change, refactor, document, then drive the gate to zero errors and zero warnings — without overrides — and only then is the work done.**

---

## 6. Getting started

```bash
# Build from source
git clone https://github.com/jpurnell/quality-gate-swift.git
cd quality-gate-swift
swift build -c release
cp .build/release/quality-gate /usr/local/bin/

# Run everything
quality-gate --check all --continue-on-failure

# Run just the correctness-critical checks
quality-gate --check build --check safety --check concurrency

# Preview and apply auto-fixes
quality-gate --fix --dry-run
quality-gate --fix

# Emit SARIF for GitHub Code Scanning
quality-gate --format sarif > results.sarif
```

Configuration lives in `.quality-gate.yml` (which checkers, exemption keywords, per-rule severity overrides, exclude patterns). Requirements: macOS 14+, Swift 6.0+. License: MIT.

---

## 7. One-paragraph summary (for quick ingestion)

quality-gate-swift is an AST-powered static-analysis gate for Swift that enforces correctness, safety, and concurrency rules on every commit and push. Its 42 checkers walk the SwiftSyntax tree rather than matching regex, so they catch structural defects — crashes, data races, unsafe pointers, unguarded division — with few enough false positives to *block* rather than merely warn. It integrates into a strict TDD workflow via git hooks, GitHub Actions (SARIF/Code Scanning), and an Xcode build phase, and dogfoods itself against its own 1,677-test suite. Its value is proven by Harbor, a shipping biofeedback product where a user-stop-mislabeled-as-completed async race survived TDD and three green gate cycles; that single failure became the specification for three new concurrency checkers, and the tool's hard-won precision (turning 1,064 vendored-SDK false positives into 0) is what makes its gate trustworthy enough to enforce.
```