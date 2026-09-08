# quality-gate-swift

Modular, AST-powered static analysis for Swift projects. This tool dogfoods itself — quality-gate-swift runs its own checkers on every commit and push.

## Quality Gate Enforcement

A git pre-commit hook runs quality-gate automatically on every commit. If the hook blocks
your commit, fix all reported issues before retrying.

**Before marking any work complete**, run and report results:
```
quality-gate --check all --exclude test --strict --continue-on-failure
```

`doc-lint` is no longer excluded. It was, and the exclusion hid nothing at the time — but it
also meant the manual command disagreed with the pre-commit hook, which runs the default set
and has always included `doc-lint`. Two commands that claim to be the same check and are not
is how a gate loses its authority.

~~Be aware of what `doc-lint` currently *is*, though, because passing it means less than it
looks: `parseLibraryTarget` takes the first target of the first `.library` product, so it
reaches **1 of 116 targets** (`QualityGateCore`). A sweep of the unexamined remainder found
eleven broken symbol links it never had the chance to see. Widening that scope is open work,
and until it lands a green `doc-lint` is a statement about 0.9% of the package.~~

**Fixed 2026-08-12 in `1d500bc`; this paragraph was stale from that day and was still being
carried forward on 2026-08-18.** `doc-lint` now calls `documentedTargets`, which enumerates
every target owning a `.docc` catalogue — **34** here — and passes each with a repeated
`--target`. `parseLibraryTarget` survives only as a last-resort fallback for a package where
nothing owns a catalogue. The eleven broken symbol links that sweep found were fixed in the
same commit.

The correction is recorded rather than deleted because the failure is instructive: the claim
outlived its fix by six days and appeared in two places that nothing compiles, so nothing
contradicted it. A checker's scope belongs in its own coverage note, which `doc-lint` now
prints on every run — that number cannot go stale, because it is computed.

`doc-code` now runs by default rather than opt-in, so both the hook and this command include
it. Exclude it with `--exclude doc-code` if a catalogue has not adopted the one-program
convention yet.

`doc-run` and `doc-claims` stay opt-in, on a stronger convention than `doc-code` asks for:
rung 2 requires an article to *run* top to bottom without trapping, rung 3 requires its
documented figures to match what that program computes. Run them with
`--check doc-run` / `--check doc-claims`. The path to promoting them is the one `doc-code`
just walked — adopt the convention by repairing the documentation, never by relaxing the
rule — so treat a red arrival as remediation work, not as a reason to weaken the checker.

### Forbidden
- Never use `--no-verify` with git commit or git push
- Never use `QG_SKIP=1` to bypass the pre-commit hook
- Never commit code with quality-gate errors or warnings

## Zero-Tolerance Coding Rules

### Safety
- No `!` (force unwrap) — use `guard let` or `if let`
- No `as!` (force cast) — use `as?` with guard
- No `try!` — use `do/catch`
- No `fatalError()` or `precondition()` in production code

### Floating-Point
- Every division must guard against zero denominator
- Tests: never use `==` for floating-point comparison — use `abs(a - b) < 1e-6`
- Use `T.ulpOfOne` for near-zero checks in production code

### Concurrency (Swift 6)
- All code must compile with `-Xswiftc -strict-concurrency=complete` — zero errors
- All shared types must conform to `Sendable`
- `@unchecked Sendable` requires `// Justification:` comment

### Testing
- Stochastic tests: always use seeded RNG, never implicit `.random()`
- Assertions: use specific expected values, not `!= 0` or `!= nil`
- Tests must be deterministic and reproducible

### Logging
- Use `os.Logger`, not `print()`, for diagnostics
- `try?` requires `// silent: <reason>` comment explaining why the error is discarded
- Catch blocks must log or rethrow — no empty catch

## Development Workflow

### TDD Cycle (mandatory)
```
DESIGN → RED (failing test) → GREEN (minimum to pass) → REFACTOR → DOCUMENT → VERIFY
```

## Companion repository

This repository is public and holds the code. The **reasoning** — master plan, design
proposals, checklists and session summaries — lives in a separate **private** companion,
cloned as a sibling:

```
quality-gate-swift/           ← here: Sources, Tests, docs, CHANGELOG
quality-gate-swift-project/   ← private: master_plan, plans, proposals, summaries
```

The split is deliberate and its rationale is in `development-guidelines/rules/
project_companion_repo.md`: a proposal records *why* a checker exists, and that answer often
names a client. A directory boundary is a better place to make the publish/don't-publish
decision than a per-sentence judgement made while writing.

`development-guidelines/` is likewise a private framework, gitignored here and cloned
alongside. A contributor without either companion can still build, test and gate this
repository; they see references by path and know what they are missing.

### Design Proposals
For non-trivial features (new checker, new protocol, architectural change):
write a design proposal in the companion's `plans/proposals/`
before writing code, and reference it by path from the code commit.

### Session Protocol
- **Start**: Read the latest file in the companion's `summaries/`
- **End**: Create a session summary in the companion's `summaries/<YYYY-MM-DD>_<TaskName>.md`

Both lived at this repository's root until 2026-09-08, when they moved to the companion so
this repository could be made public. `.quality-gate.yml`'s `masterPlanPath` points at the
companion; a checker that needs the plan reports it as unavailable rather than passing, so a
clone without the companion cannot mistake absence for compliance.

## Build Feedback

After editing any `.swift` file, `swift build` runs automatically via PostToolUse hook.
Fix all build errors before proceeding to the next change.

## Architecture

61 SPM targets. Key module groups:
- **QualityGateCore**: Diagnostic models, CheckResult, Configuration, Reporters
- **QualityGateCLI**: ArgumentParser entry point, checker orchestration
- **Auditors**: SafetyAuditor, ConcurrencyAuditor, RecursionAuditor, etc.
- **IJS modules**: IJSSensor, IJSAggregator, IJSRefiner, IJSPolicyDiscovery, ConsistencyChecker

## References

These live in the private `development-guidelines` framework, cloned alongside. Paths are
given so a reader knows what governs this code even without access to it.

- Full coding rules: `development-guidelines/rules/coding_rules.md`
- TDD contract: `development-guidelines/rules/test_driven_development.md`
- Enforcement architecture: `development-guidelines/rules/enforcement.md`
- Session workflow: `development-guidelines/rules/session_workflow.md`
- Companion-repo policy: `development-guidelines/rules/project_companion_repo.md`
