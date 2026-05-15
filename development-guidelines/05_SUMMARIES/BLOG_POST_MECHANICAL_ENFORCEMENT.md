# We Had 13 Documents. We Shipped 55 Errors. Here's What Actually Works.

We had 13 documents describing our development process. Coding rules. TDD contracts. Session workflows. Design proposal templates. Release checklists. Floating-point formatting guides. DocC guidelines. Performance standards.

None of them prevented us from shipping 55 errors and 53 warnings in a single batch of commits.

## What Happened

quality-gate-swift is a modular, AST-powered static analysis tool for Swift projects. It has 25 checkers, 1,130+ tests, and 61 SPM targets. It is, by any measure, a serious tool for enforcing code quality. It is also the tool that failed to catch its own quality violations because nobody ran it.

The failure happened during a TDD sprint to build five new modules for the Institutional Judgment System: IJSSensor, IJSAggregator, IJSRefiner, IJSPolicyDiscovery, and ConsistencyChecker. The AI assistant (Claude Code) followed the TDD workflow — DESIGN, RED, GREEN, REFACTOR, DOCUMENT — exactly as prescribed. Tests were written first. Code was written to pass them. Refactoring happened. Documentation was added.

But the workflow has six steps, not five. The sixth step is VERIFY: run the quality gate before committing. The AI skipped it. Every time. Across five modules and dozens of commits. The checklist said VERIFY. The session workflow document said VERIFY. The TDD contract said VERIFY. The AI read none of them during the actual commit cycle.

When we finally ran the quality gate, the damage report was brutal:

- **Floating-point exact equality in tests.** `XCTAssertEqual(score, 0.85)` instead of `XCTAssertEqual(score, 0.85, accuracy: 1e-6)`. The tests passed on the developer's machine. They would have failed intermittently in CI on different architectures.
- **Unreachable dead code.** Entire functions and branches that could never execute, left behind from refactoring passes that the AI considered "complete."
- **Missing documentation.** Public APIs with no `///` doc comments — in a project whose own doc-coverage checker flags exactly this violation.
- **Weak assertions.** Tests asserting `!= 0` or `!= nil` instead of checking for specific expected values. These tests pass when the code is wrong in a different way than expected.
- **Unseeded random in tests.** Calls to `.random()` without a seeded RNG, making tests non-deterministic and unreproducible.
- **Unguarded division.** Division operations with no zero-denominator guard — exactly the kind of crash-at-runtime bug that a quality gate exists to prevent.
- **Silent error swallowing.** `try?` without a `// silent:` comment explaining why the error was intentionally discarded. `catch` blocks that did nothing.

Fifty-five errors. Fifty-three warnings. In a project that builds the tool designed to catch these problems.

## Documents Are Suggestions

Here is a partial list of documents that existed at the time of the failure:

1. `01_CODING_RULES.md` — 61KB of coding standards
2. `09_TEST_DRIVEN_DEVELOPMENT.md` — TDD contract with mandatory VERIFY step
3. `07_SESSION_WORKFLOW.md` — Start/end session protocol
4. `05_DESIGN_PROPOSAL.md` — Design-before-code template
5. `04_IMPLEMENTATION_CHECKLIST.md` — Step-by-step implementation tracker
6. `08_FLOATING_POINT_FORMATTING.md` — IEEE 754 handling rules
7. `RELEASE_CHECKLIST.md` — Pre-release verification
8. `TESTING.md` — Test quality standards
9. `PERFORMANCE.md` — Performance guidelines
10. `03_DOCC_GUIDELINES.md` — Documentation standards
11. `00_MASTER_PLAN.md` — Project architecture and roadmap
12. `11_CI_QUALITY_GATE.md` — CI integration guide
13. `CLAUDE.md` — AI-specific instructions

Thirteen documents. Some of them quite good. All of them optional in practice.

The root cause was not a lack of documentation. The root cause was that documentation describes the ideal process, and nothing in the development environment forced adherence to it. The AI assistant loaded CLAUDE.md at session start, acknowledged the rules, and then got absorbed in the implementation work. By the time it was writing its fifteenth test file, the VERIFY step was a distant memory from a document it had read an hour ago.

This is not an AI-specific problem. Human developers do the same thing. The difference is that a human might notice they haven't run the linter in a while. An AI assistant, operating in a tight edit-test loop, has no ambient awareness of accumulated drift.

## What Actually Works: Mechanical Enforcement

The fix was not another document. The fix was four layers of mechanical enforcement that make it impossible to commit code that fails quality standards.

### Layer 1: Pre-Commit Hook (Local, Fast, 5-10 Seconds)

A git pre-commit hook runs `quality-gate` automatically on every `git commit`. Not sometimes. Not when you remember. Every time.

The hook runs the fast, AST-only checks: safety, concurrency, recursion, pointer-escape, doc-coverage, floating-point safety, test-quality, logging, release-readiness, accessibility, stochastic-determinism, status, context, consistency, and dependency-audit. These are pure SwiftSyntax analysis — no process spawning, no builds, no test execution.

If any check produces an error, the commit is rejected. You cannot proceed until you fix the issue. The hook does not care that you are in the middle of a flow state. It does not care that the fix is "trivial." It does not negotiate.

The checks that are *excluded* from pre-commit are equally important: `build`, `test`, `doc-lint`, `disk-clean`, `memory-builder`, `swift-version`, and `unreachable`. These are excluded because they spawn processes (`swift build`, `swift test`, DocC), require IndexStore artifacts from prior builds, or have side effects. Running them on every commit would add 30-90 seconds and make developers hate the hook enough to bypass it. The fast AST checks catch 90% of issues in under 10 seconds. That is the right trade-off.

### Layer 2: Pre-Push Hook (Local, ~15 Seconds)

A git pre-push hook runs `swift build` and verifies zero compiler errors before code reaches the remote. This catches import errors, type mismatches, and other issues that AST analysis alone cannot detect.

Pre-push is the right place for this because pushes happen less frequently than commits. A developer might make ten commits before pushing. The build check runs once, not ten times.

### Layer 3: CI Workflow (Remote, Comprehensive)

A reusable GitHub Actions workflow runs the full quality gate on every push and pull request. This includes everything from Layers 1 and 2, plus the slow checks: `swift test` (zero test failures), unreachable code detection (needs IndexStore), `doc-lint` (needs DocC tooling), and `swift-version` compliance.

The reusable workflow builds quality-gate-swift from `main` on every CI run. There are no version pins. There are no cached binaries. When a new checker or heuristic improvement is added to quality-gate-swift, every consuming project picks it up on its next CI run. The bar only rises.

This workflow is used across 24+ projects. One line of YAML gives any project the full enforcement stack.

### Layer 4: CLAUDE.md (AI-Specific Enforcement)

CLAUDE.md is loaded into the AI assistant's context at the start of every session. It contains zero-tolerance coding rules, a mandatory quality-gate command to run before marking work complete, and explicit prohibitions against bypass patterns.

This layer exists because Layers 1-3 only trigger at git operations. The AI assistant might edit twenty files before its first commit attempt. CLAUDE.md catches process-level mistakes — like skipping the DESIGN phase or not writing tests first — that hooks cannot detect.

The key design decision: CLAUDE.md is kept under 150 lines. Short enough to fit in the AI's working context without being compacted away. Every rule is concrete and actionable. No philosophy, no rationale paragraphs, no "see document X for details." The AI never read document X. That was the whole problem.

## Cross-Project Propagation

The enforcement stack ships as part of `development-guidelines` — a shared template repository that gets cloned into every project. When a project adopts the guidelines:

1. `scripts/install-hooks.sh` installs the pre-commit and pre-push hooks. The script is idempotent — marker-based detection (`# quality-gate-swift managed hook`) allows safe re-runs without clobbering custom hooks.
2. `scripts/migrate.sh` applies structural updates to the guidelines directory without overwriting user-customized content. A `.version` marker tracks migration state.
3. `templates/CLAUDE.md` provides a ready-to-customize AI enforcement template.
4. The CI workflow is a single `uses:` line pointing at the reusable workflow in the quality-gate-swift repo.

quality-gate-swift itself is installed globally — `scripts/install.sh` clones to `~/.quality-gate-swift`, builds a release binary, and copies it to `/usr/local/bin/quality-gate`. This is the SwiftLint distribution model, not the SPM plugin model. quality-gate-swift depends on SwiftSyntax, which adds ~100MB of build artifacts. Making every consuming project pull that dependency through SPM would be absurd. The tool is a tool, not a library.

## The Escape Hatch Design

There is exactly one escape hatch: `QG_SKIP=1 git commit -m "..."`. It prints a prominent warning and allows the commit through. It exists for genuine emergencies — infrastructure failures, CI outages, situations where the quality gate binary itself is broken.

Why `QG_SKIP` instead of `--no-verify`? Because `--no-verify` skips ALL git hooks, including the pre-push build check. `QG_SKIP` skips only the quality gate while leaving other hooks intact. It is a scalpel, not a sledgehammer.

AI assistants are forbidden from using either `QG_SKIP` or `--no-verify`. This is enforced by CLAUDE.md. The AI has no legitimate emergency that justifies bypassing the gate. If the gate fails, the AI's job is to fix the code, not circumvent the check.

## Results

Every commit in every project that adopts development-guidelines is now gated. The 55-error incident cannot recur because the pre-commit hook would have rejected the first commit that introduced a floating-point exact equality. The AI would have been forced to fix it immediately, in context, while the code was still fresh — instead of forty commits later, during a cleanup session, with degraded understanding of the original intent.

The enforcement propagates automatically. When we add a new checker to quality-gate-swift — say, an auditor for unbounded collection growth — every project picks it up on its next CI run, and every developer picks it up the next time they update their global install. No version bumps. No dependency updates. No "please update your tooling" emails that everyone ignores.

## The Takeaway

If a rule matters, it needs a hook, not a document.

Documents describe intent. Hooks enforce behavior. We spent months writing careful, thorough, well-organized documents about how to write quality Swift code. Then an AI assistant — one specifically instructed to follow those documents — ignored them all and shipped 55 errors.

The documents were not wrong. They were just not enforcement. The moment we replaced "you should run the quality gate" with "the quality gate runs whether you want it to or not," the problem disappeared. Not gradually. Immediately.

Thirteen documents told us what to do. Four hooks made us do it.
