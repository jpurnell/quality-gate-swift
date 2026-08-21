# quality-gate-swift — Overview & Case Study

*A modular, AST-powered quality gate for Swift projects. This document is both a plain-language introduction and a structured source document — it is written to be read by a person in five minutes, or ingested by an LLM (NotebookLM, Claude, etc.) as reference material about how the tool works and how it fits into product development.*

---

## 1. What it is

**quality-gate-swift** is a static-analysis tool that enforces correctness, safety, concurrency, documentation, and security rules on Swift codebases — automatically, on every commit and every push.

It is not a linter that nags about whitespace. It is a **gate**: code that violates a correctness or safety rule does not get committed. Whitespace and style rules exist too, but they are *advisory* by design — the gate blocks on things that can crash a shipping app, not on formatting.

Three numbers frame it:

- **46 checkers**, each an independent Swift package module with its own tests and documentation.
- **3,245 tests** covering the checkers themselves — the tool is held to the standard it enforces.
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
- **It dogfoods itself.** quality-gate-swift runs its own 46 checkers on every push. The tool is subject to its own gate.

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

## 5. Case study: 22 known-good packages

Harbor is the case where a real bug got past the tool and the tool learned from it. This is the
opposite experiment, and it turned out to be the more productive one.

The gate was pointed at **22 widely-used open-source Swift packages** — Alamofire, swift-nio,
GRDB, swift-collections, The Composable Architecture, SwiftyJSON, swift-algorithms, Ignite and
others. None of them are our code. All of them are heavily used and heavily reviewed. That
changes what a finding *means*: against known-good code, a finding is not news about the package.
**It is a hypothesis about the tool.**

The survey did not turn up a handful of false positives. It turned up whole classes of them, and
two performance defects that had been invisible because they looked like constants.

### 1. Name matching wearing the costume of analysis

Walking the AST is not automatically semantic. SwiftSyntax knows that `return sql` is an
identifier named `sql`; it cannot know whether that resolves to the enclosing property or to a
local declared two lines earlier. Three real shapes, from three unrelated authors:

```swift
// GRDB — a local shadows the property
var sql: String { if let raw { let sql = String(raw); return sql }; return "" }

// Alamofire — the key path addresses another type entirely
var retryCount: Int { mutableState.read(\.retryCount) }

// GRDB — one of fourteen encode(_:) overloads in a single file
mutating func encode(_ value: Int16) throws { encode(value.databaseValue) }   // → encode(DatabaseValue)
```

The checker reported all three as infinite recursion. Argument labels are part of a function's
identity but not all of it — Swift chooses between same-labelled overloads by *parameter type*,
which no syntactic pass can do. The rules now resolve what syntax can resolve, and where they
cannot, they say so rather than guess.

### 2. A base case the checker could not see

"Bounded" was tested by looking for a `guard`. Everything else that ends a descent was invisible:

- **GRDB's `SQLExpression.between`** terminates by returning `self.init(…)` — a call, so no base
  case was recognised.
- **Ignite's `flatten(_:)`** reaches `[]` as the value of an `if` *expression*, with no `return`
  keyword for a statement-shaped heuristic to find.
- **swift-collections' `_subtracting_slow`** reaches its guard through two nested closures inside
  a returned expression, which the walker never descended into.

### 3. Two passes disagreeing, and a text scan hiding it

The index-backed pass decided whether a cycle was bounded by scanning body **text** for the
literal `"guard "`, inside lines delimited by counting braces with no awareness of strings or
comments. The AST pass already knew the answer properly. Where they disagreed, the text scan won
— and silently. swift-async-algorithms' `AsyncBufferedByteIterator` is the clean example: its
`reloadBufferAndNext()` ↔ `next()` really is a cycle, and really is bounded, by
`if finished { return nil }` and a fast-path early return. Neither is a `guard`, so it was
reported as unbounded.

### 4. Quadratic work disguised as a constant

Each finding needs a source location, and each location needs a `SourceLocationConverter`, which
indexes every line in the file. Constructed once per file that is cheap; constructed inside a
method the framework calls per syntax node — or per function — it is quadratic in file size, and
it looks like ordinary work in every profile until you plot it against input size.

| checker | growth before | growth after |
| --- | --- | --- |
| `safety` | n^2.01 | n^0.83 |
| `test-quality` | n^1.99 | n^0.98 |
| `doc-coverage` | n^1.56 | n^0.74 |
| `complexity` | n^1.81 | n^0.83 |

`complexity` on a 259 KB file went from **53.83s to 5.50s**. The full 22-package sweep went from
**39.5 minutes to 18.9**.

### The scoreboard

Across the 22 packages, the recursion checker alone went from **174 errors and 279 warnings to 47
and 10** — and the survivors were read individually to confirm they are real.

### What the process taught, which matters more than the fixes

Three separate times a fix looked obviously correct and the corpus disagreed:

- Recording base cases for computed properties changed **nothing** — the corpus run came back
  byte-identical — because the index names a property's accessors `getter:name` while the syntax
  tree records `name`. The two never met. Reading the code would not have revealed that; running
  it did.
- Bridging the two passes on *line numbers* matched barely half the corpus, because a
  declaration's line drifts between them: one points at an attribute, the other at the name.
- An early attempt to have the index pass adjudicate self-calls reported **207 findings**, all
  because it had no base-case data to filter them with.

Every one of those was a place where two systems had to agree on an identifier and agreement was
*assumed* rather than checked. The survey's real output is not the fix list. It is the practice:
**measure the fix against a corpus you did not write, before believing it.**

### Why this matters if you are considering the tool

A gate is only as valuable as it is trusted, and it is only trusted if nearly every finding is
real. Harbor proved that with a false-positive storm (1,064 → 0). The survey is the same lesson
run deliberately rather than discovered by accident — and it is repeatable. The corpus is public
packages; the method is one command per package and a diff.

---

## 6. How it integrates with product development

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

## 7. Getting started

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

## 8. One-paragraph summary (for quick ingestion)

quality-gate-swift is an AST-powered static-analysis gate for Swift that enforces correctness, safety, and concurrency rules on every commit and push. Its 46 checkers walk the SwiftSyntax tree rather than matching regex, so they catch structural defects — crashes, data races, unsafe pointers, unguarded division — with few enough false positives to *block* rather than merely warn. It integrates into a strict TDD workflow via git hooks, GitHub Actions (SARIF/Code Scanning), and an Xcode build phase, and dogfoods itself against its own 3,245-test suite. Its value is proven by Harbor, a shipping biofeedback product where a user-stop-mislabeled-as-completed async race survived TDD and three green gate cycles; that single failure became the specification for three new concurrency checkers, and the tool's hard-won precision (turning 1,064 vendored-SDK false positives into 0) is what makes its gate trustworthy enough to enforce. That precision is now maintained deliberately rather than discovered by accident: the gate is regularly run against a corpus of 22 widely-used open-source Swift packages (Alamofire, swift-nio, GRDB, swift-collections, The Composable Architecture and others), where every finding is treated as a hypothesis about the tool rather than news about the package — a survey that cut the recursion checker's output across that corpus from 174 errors and 279 warnings to 47 and 10, uncovered four classes of false positive rooted in name-matching rather than name-resolution, and exposed quadratic location-conversion work that had been invisible in profiles, halving whole-corpus sweep time from 39.5 to 18.9 minutes.
```