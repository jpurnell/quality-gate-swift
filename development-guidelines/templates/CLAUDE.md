# [PROJECT_NAME]

## Quality Gate Enforcement

A git pre-commit hook runs quality-gate automatically on every commit. If the hook blocks
your commit, fix all reported issues before retrying.

**Before marking any work complete**, run and report results:
```
quality-gate --check all --exclude test --exclude doc-lint --strict --continue-on-failure
```

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

### Collections & Loops
- All loops must have maximum iteration bounds
- All growing collections must have maximum size limits

## Development Workflow

### TDD Cycle (mandatory)
```
DESIGN → RED (failing test) → GREEN (minimum to pass) → REFACTOR → DOCUMENT → VERIFY
```

### Design Proposals
For non-trivial features (new module, new protocol, architectural change):
write a design proposal in `development-guidelines/02_IMPLEMENTATION_PLANS/PROPOSALS/`
before writing code.

### Session Protocol
- **Start**: Offer to run `./development-guidelines/scripts/update.sh` to pull latest framework files
- **Start**: Read the latest file in `development-guidelines/05_SUMMARIES/`
- **End**: Create a session summary in `development-guidelines/05_SUMMARIES/YYYY-MM-DD_TaskName.md`

## Build Feedback

After editing any `.swift` file, `swift build` runs automatically via PostToolUse hook.
Fix all build errors before proceeding to the next change.

## Git Hooks

Pre-commit and pre-push hooks must be installed:
```
./development-guidelines/scripts/install-hooks.sh
```

Verify: `ls .git/hooks/pre-commit` should show the managed hook.

## References

- Full coding rules: `development-guidelines/00_CORE_RULES/01_CODING_RULES.md`
- TDD contract: `development-guidelines/00_CORE_RULES/09_TEST_DRIVEN_DEVELOPMENT.md`
- Enforcement architecture: `development-guidelines/00_CORE_RULES/12_ENFORCEMENT.md`
- Session workflow: `development-guidelines/00_CORE_RULES/07_SESSION_WORKFLOW.md`
