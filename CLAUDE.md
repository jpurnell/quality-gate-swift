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

Be aware of what `doc-lint` currently *is*, though, because passing it means less than it
looks: `parseLibraryTarget` takes the first target of the first `.library` product, so it
reaches **1 of 116 targets** (`QualityGateCore`). A sweep of the unexamined remainder found
eleven broken symbol links it never had the chance to see. Widening that scope is open work,
and until it lands a green `doc-lint` is a statement about 0.9% of the package.

`doc-code` now runs by default rather than opt-in, so both the hook and this command include
it. Exclude it with `--exclude doc-code` if a catalogue has not adopted the one-program
convention yet.

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

### Design Proposals
For non-trivial features (new checker, new protocol, architectural change):
write a design proposal in `development-guidelines/project/plans/proposals/`
before writing code.

### Session Protocol
- **Start**: Read the latest file in `development-guidelines/project/summaries/`
- **End**: Create a session summary in `development-guidelines/project/summaries/<YYYY-MM-DD>_<TaskName>.md`

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

- Full coding rules: `development-guidelines/rules/coding_rules.md`
- TDD contract: `development-guidelines/rules/test_driven_development.md`
- Enforcement architecture: `development-guidelines/rules/enforcement.md`
- Session workflow: `development-guidelines/rules/session_workflow.md`
