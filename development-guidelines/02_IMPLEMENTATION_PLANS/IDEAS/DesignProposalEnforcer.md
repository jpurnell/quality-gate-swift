# Design Proposal: Design Proposal Enforcer

**Date:** 2026-05-15
**Status:** Proposed
**Author:** Claude (AI Assistant)

---

## Objective

Mechanically enforce the design-first workflow by detecting new SPM targets that lack a corresponding design proposal. If you add a new module to `Package.swift` without a proposal in `02_IMPLEMENTATION_PLANS/PROPOSALS/`, the quality gate blocks your commit.

**Master Plan Reference:** Enforcement architecture (12_ENFORCEMENT.md) — this adds a new layer to the "documents are suggestions, hooks are guardrails" philosophy.

---

## Problem Statement

On 2026-05-15, a ProcessSafetyAuditor module was implemented — new source directory, Package.swift target, CLI registration, tests — without a design proposal. The existing enforcement stack caught zero-tolerance coding violations (pre-commit hook) and build failures (pre-push hook), but nothing prevented skipping the DESIGN phase.

The gap: **we enforce code quality mechanically but enforce process quality with documents.** This checker closes that gap for the most impactful process step.

---

## Proposed Architecture

### New Checker Module

```
Sources/DesignProposalEnforcer/
├── DesignProposalEnforcer.swift     — QualityChecker implementation
└── ProposalMatcher.swift            — Matching logic between targets and proposals
```

### How It Works

1. Parse `Package.swift` to extract all target names
2. Read a baseline of "known targets" from configuration (or from git history)
3. For each target NOT in the baseline, look for a matching proposal file in `development-guidelines/02_IMPLEMENTATION_PLANS/` (any subdirectory: PROPOSALS/, COMPLETED/, UPCOMING/)
4. Flag any new target without a matching proposal

### What Counts as a "Match"

A target named `FooBarAuditor` matches a proposal if any `.md` file in `02_IMPLEMENTATION_PLANS/` contains the target name in:
- The filename (case-insensitive): `FooBarAuditor.md`, `foo-bar-auditor.md`, `FooBar_design.md`
- The first-level heading: `# Design Proposal: FooBarAuditor`
- A YAML frontmatter `target:` field: `target: FooBarAuditor`

This is intentionally fuzzy — we want to catch "no proposal exists at all," not enforce a specific naming convention.

### Baseline: What Counts as "New"

A target is considered new if it doesn't appear in the checker's baseline list. The baseline is populated from:

**Option A — Configuration-based (recommended):**
```yaml
# .quality-gate.yml
designProposal:
  baselineTargets:
    - QualityGateCore
    - SafetyAuditor
    - BuildChecker
    # ... all existing targets at adoption time
  proposalPaths:
    - "development-guidelines/02_IMPLEMENTATION_PLANS"
  exemptPatterns:
    - "*Tests"      # test targets never need proposals
    - "*TestKit"    # test helper targets
```

The baseline is set once when the checker is adopted. Any target added after that point needs a proposal.

**Option B — Git-based:**
Compare current `Package.swift` targets against the previous commit's targets. Only flag targets added in uncommitted changes.

**Recommendation:** Option A. Git-based detection is fragile (rebases, squashes, amends change what "previous" means) and adds process spawning to a checker that should be pure file reads. A static baseline in config is simple and explicit.

---

## API Surface

```swift
public struct DesignProposalEnforcer: QualityChecker, Sendable {
    public let id = "design-proposal"
    public let name = "Design Proposal Enforcer"
    
    public init()
    public func check(configuration: Configuration) async throws -> CheckResult
}
```

### Configuration

```yaml
# .quality-gate.yml
designProposal:
  baselineTargets: [...]        # targets that predate this checker
  proposalPaths:                # where to look for proposals
    - "development-guidelines/02_IMPLEMENTATION_PLANS"
  exemptPatterns:               # targets that never need proposals
    - "*Tests"
    - "*TestKit"
    - "*.docc"
```

### Diagnostic Output

```
⚠ [design-proposal] WARNING
  ⚠️  warning: New target 'ProcessSafetyAuditor' has no design proposal
     → Package.swift
     💡 Create a proposal in development-guidelines/02_IMPLEMENTATION_PLANS/PROPOSALS/ProcessSafetyAuditor.md
```

Severity: **warning** (not error). This allows committing work-in-progress code with a proposal pending, while still making the gap visible. The quality gate run before marking work complete (which uses `--strict`) treats warnings as failures.

---

## Constraints & Compliance

- **Concurrency:** Stateless struct, `Sendable` compliant
- **Safety:** No force unwraps. File reads use guard-let. Missing config gracefully skips the check.
- **Determinism:** Pure file system reads — no network, no randomness
- **Performance:** Reads Package.swift once, scans proposal directory once. No process spawning. Expected <0.2s.
- **Dependencies:** QualityGateCore only — no SwiftSyntax needed (Package.swift parsing uses regex, not AST)

---

## Adversarial Review

### False Positives — What legitimate code would this flag incorrectly?

1. **Rapid prototyping.** Someone creates a module to explore an idea before writing a formal proposal. The checker flags it immediately.
   - **Mitigation:** Warning severity, not error. You can still commit. The flag is visible in `--strict` mode (which blocks "done" declarations), but doesn't block exploratory commits.

2. **Refactoring: splitting a target.** You split `QualityGateCore` into `QualityGateCore` and `QualityGateModels`. The new `QualityGateModels` target doesn't need an independent design proposal — it's part of a refactor.
   - **Mitigation:** Add the new target to `baselineTargets` in config, or add it to `exemptPatterns`. Alternatively, create a brief refactor proposal (a few lines acknowledging the split).

3. **Generated code targets.** Some projects generate targets (SwiftGen, Sourcery). These don't need proposals.
   - **Mitigation:** `exemptPatterns` with glob matching: `"*Generated*"`.

4. **Existing projects adopting the checker.** All existing targets would be flagged without a baseline.
   - **Mitigation:** The `baselineTargets` config is populated at adoption time. `migrate.sh` could auto-generate it from the current Package.swift.

### False Negatives — What would this miss?

1. **Architectural changes within an existing module.** Adding a new protocol, rewriting a subsystem, or changing concurrency models — all within an existing target. The checker only sees target-level changes.
   - **Mitigation:** This is out of scope. The checker enforces "new modules need proposals," not "all architectural work needs proposals." The latter requires AI judgment (CLAUDE.md), not mechanical enforcement.

2. **Proposal exists but is empty/stub.** Someone creates `Proposals/NewModule.md` with just a title to satisfy the checker.
   - **Mitigation:** Accept this. If someone creates a stub proposal, they're acknowledging the process exists. The adversarial review section being missing would be visible in code review. Enforcing proposal quality is a judgment call, not a mechanical check.

3. **Target added via dependency, not local code.** External package products show up in the dependency graph but aren't local targets.
   - **Mitigation:** The checker only looks at `.target()` and `.executableTarget()` entries, not `.product()` references. No false negatives here.

### What could go wrong at scale?

1. **Baseline drift.** If someone adds a target and puts it in `baselineTargets` instead of writing a proposal, the checker is bypassed. This is a discipline issue — same as `QG_SKIP=1`. The commit message and diff would show the config change, making it visible in review.

2. **Proposal directory doesn't exist.** If a project hasn't set up `development-guidelines/02_IMPLEMENTATION_PLANS/`, every target would be flagged.
   - **Mitigation:** If `proposalPaths` directories don't exist, emit a note and skip the check. Don't fail on missing infrastructure.

3. **Package.swift parsing breaks.** Regex-based parsing of Package.swift is fragile — complex manifest files with conditional targets, `#if` blocks, or multiline expressions might not parse correctly.
   - **Mitigation:** Use the same `PackageManifestParser` that `ConcurrencyAuditor` already uses (it handles these cases). If parsing fails, skip the check with a note — don't block commits on parser bugs.

---

## Dependencies

**Internal:**
- `QualityGateCore` — `QualityChecker` protocol, `Configuration`, `Diagnostic`
- `PackageManifestParser` (already exists in the codebase) — for Package.swift target extraction

**External:** None

---

## Test Strategy

### Unit Tests

| Test | Input | Expected |
|------|-------|----------|
| New target with proposal | Package.swift has `FooAuditor`, proposal exists | Pass |
| New target without proposal | Package.swift has `FooAuditor`, no proposal | Warning |
| Baseline target without proposal | Target in `baselineTargets` config | Pass |
| Test target exemption | Target named `FooAuditorTests` | Pass (exempt) |
| Proposal in COMPLETED/ | Proposal moved to COMPLETED/ after implementation | Pass |
| Case-insensitive match | Target `FooBar`, proposal `foobar.md` | Pass |
| Missing proposal directory | `proposalPaths` points to nonexistent dir | Pass (skip with note) |
| Empty Package.swift | No targets | Pass |

### Integration Test
- Run against quality-gate-swift itself with current `baselineTargets`
- Verify ProcessSafetyAuditor (if still without proposal at that point) is flagged
- Verify all existing targets pass

**Reference Truth:** The test directly creates Package.swift content and proposal files — no external reference needed.

---

## Documentation Strategy

- **Type:** API Docs Only
- DocC comments on `DesignProposalEnforcer` and `ProposalMatcher`
- Update `12_ENFORCEMENT.md` check table with `design-proposal` entry
- Update `05_DESIGN_PROPOSAL.md` to mention the mechanical enforcer exists

---

## Implementation Order

1. Add `designProposal` section to `Configuration.swift`
2. RED: Write `DesignProposalEnforcerTests` — all 8 test cases failing
3. GREEN: Implement `DesignProposalEnforcer` and `ProposalMatcher`
4. Wire into Package.swift (library + test target) and CLI
5. Populate `baselineTargets` in quality-gate-swift's `.quality-gate.yml`
6. VERIFY: quality gate passes with 0 errors, 0 warnings
7. Update `12_ENFORCEMENT.md` and `05_DESIGN_PROPOSAL.md`

---

## Open Questions

1. Should the checker also validate that the proposal has an adversarial review section (heading search), or is that over-enforcement?
2. Should `migrate.sh` / `update.sh` auto-generate `baselineTargets` from the current Package.swift when a project first adopts this checker?
3. Should the severity be error (blocks all commits) or warning (blocks `--strict` only)? Proposal recommends warning to allow WIP commits.
