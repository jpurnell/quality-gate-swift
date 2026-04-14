# Design Proposal: FixableChecker Protocol + StatusAuditor Remediation

## 1. Objective

Add an auto-fix capability to quality-gate-swift so that checkers can not only detect problems but repair them — starting with StatusAuditor, which can generate a correct Master Plan from actual code state to remediate drift in existing projects.

**Master Plan Reference:** Phase 4 — Community & Polish

**Motivation:** StatusAuditor (designed separately) detects that your Master Plan says "Stub only" while the module has 1,186 lines. But detection alone doesn't help existing projects clean up. A developer adopting quality-gate-swift on a 6-month-old project with a rotting Master Plan needs `quality-gate --check status --fix` to produce the correct status document — not just a list of 30 diagnostics they have to manually reconcile.

**The fix must be surgical, not destructive:**
- Only patch provably-wrong sections (checkboxes, test counts, "Stub only" text)
- Preserve human-authored prose, project context, and editorial decisions
- Show a diff before applying (opt-in, not automatic)
- Work on existing projects with messy, incomplete, or missing docs

## 2. Proposed Architecture

### Layer 1: FixableChecker Protocol (in QualityGateCore)

**New file:** `Sources/QualityGateCore/FixableChecker.swift`

```swift
/// A checker that can also fix the issues it finds.
///
/// Checkers that implement this protocol provide a `fix()` method
/// that applies the `suggestedFix` from their diagnostics programmatically.
/// The CLI invokes this only when `--fix` is passed.
public protocol FixableChecker: QualityChecker {

    /// Describes what this checker's fix mode does.
    ///
    /// Shown to the user before applying fixes so they understand the impact.
    var fixDescription: String { get }

    /// Apply fixes for the given diagnostics.
    ///
    /// - Parameters:
    ///   - diagnostics: The diagnostics to fix (from a prior `check()` call).
    ///   - configuration: Project-specific configuration.
    /// - Returns: A fix result describing what was changed.
    func fix(
        diagnostics: [Diagnostic],
        configuration: Configuration
    ) async throws -> FixResult
}

/// The result of applying fixes.
public struct FixResult: Sendable {
    /// Files that were modified, with before/after descriptions.
    public let modifications: [FileModification]

    /// Diagnostics that could not be auto-fixed (require manual intervention).
    public let unfixed: [Diagnostic]

    /// Whether any files were actually changed.
    public var hasChanges: Bool { !modifications.isEmpty }
}

/// A single file modification made by a fixer.
public struct FileModification: Sendable {
    /// Path to the modified file.
    public let filePath: String

    /// Human-readable description of what changed.
    public let description: String

    /// Number of lines changed.
    public let linesChanged: Int
}
```

### Layer 2: StatusAuditor Remediation (in StatusAuditor module)

**New files:**
- `Sources/StatusAuditor/StatusRemediator.swift` — Generates corrected document content
- `Sources/StatusAuditor/MasterPlanGenerator.swift` — Produces correct Master Plan sections from actual state

The remediation pipeline:

```
1. ProjectStateCollector    →  Actual module states (line counts, test counts, existence)
2. MasterPlanParser         →  Documented module states (checkboxes, descriptions)
3. StatusValidator          →  Diagnostics (what's wrong)
4. StatusRemediator         →  Patches (what the correct text should be)
5. Apply patches            →  Write corrected sections to Master Plan
```

### Layer 3: CLI --fix Flag

**Modified file:** `Sources/QualityGateCLI/QualityGateCLI.swift`

```swift
@Flag(help: "Apply auto-fixes for supported checkers")
var fix: Bool = false

@Flag(help: "Show what --fix would change without applying")
var dryRun: Bool = false
```

When `--fix` is passed:
1. Run `check()` as normal
2. For each checker that conforms to `FixableChecker` and produced diagnostics:
   a. Show `fixDescription` to the user
   b. If `--dry-run`, show the diff and stop
   c. Otherwise, call `fix(diagnostics:configuration:)`
   d. Report `FixResult` (files modified, unfixed diagnostics)

### Layer 4: Bootstrap for Existing Projects

**New file:** `Sources/StatusAuditor/StatusBootstrapper.swift`

For projects that don't have a Master Plan at all, or have one that's so far gone it's easier to start fresh:

```swift
/// Generates a complete Master Plan from actual project state.
///
/// Used when a project adopts quality-gate-swift and needs
/// initial status documentation, or when drift is so severe
/// that patching individual sections would be worse than regenerating.
public struct StatusBootstrapper {
    /// Generate a Master Plan from actual project state.
    ///
    /// - Parameters:
    ///   - projectRoot: Root directory of the Swift project.
    ///   - configuration: Project configuration.
    /// - Returns: Complete Master Plan markdown content.
    public func generateMasterPlan(
        projectRoot: URL,
        configuration: Configuration
    ) async throws -> String
}
```

This is invoked via `quality-gate --check status --bootstrap` and produces a complete, correct Master Plan that the developer can then customize with project-specific prose.

## 3. API Surface

### StatusAuditor (extended)

```swift
public struct StatusAuditor: FixableChecker, Sendable {
    public let id = "status"
    public let name = "Status Auditor"

    public let fixDescription = """
    Patches Master Plan and Implementation Checklist to match actual code state:
    - Updates module completion checkboxes ([ ] → [x] or vice versa)
    - Corrects test counts to match actual swift test output
    - Removes "Stub only" descriptions for implemented modules
    - Updates "Last Updated" date
    - Syncs Implementation Checklist with Master Plan
    Preserves all human-authored prose and project-specific context.
    """

    public func check(configuration: Configuration) async throws -> CheckResult
    public func fix(diagnostics: [Diagnostic], configuration: Configuration) async throws -> FixResult
}
```

### Remediation Patch Types

```swift
/// A specific patch to apply to a status document.
enum StatusPatch: Sendable {
    /// Change a checkbox from incomplete to complete (or vice versa).
    case checkbox(line: Int, moduleName: String, newState: Bool)

    /// Replace a module description (e.g., "Stub only" → "Code safety + OWASP security (83 tests)").
    case description(line: Int, moduleName: String, newDescription: String)

    /// Update a test count in a description.
    case testCount(line: Int, moduleName: String, oldCount: Int, newCount: Int)

    /// Update the "Last Updated" date.
    case lastUpdated(line: Int, newDate: String)

    /// Update a roadmap phase label (e.g., "(CURRENT)" → "(COMPLETE)").
    case phaseLabel(line: Int, phaseName: String, newLabel: String)

    /// Add a missing module entry.
    case addModule(afterLine: Int, entry: String)

    /// Remove a phantom module entry (references module not in Package.swift).
    case removeModule(line: Int, moduleName: String)
}
```

## 4. MCP Schema

**N/A.** CLI-only feature. The `--fix` flag is a terminal operation.

## 5. Constraints & Compliance

- **Non-destructive by default:** `--fix` requires explicit opt-in. Without it, StatusAuditor is read-only.
- **Dry-run first:** `--dry-run` shows the diff without writing. The CLI should recommend this on first use.
- **Surgical patches:** Only modify provably-wrong content. Never rewrite human-authored prose.
- **Backup before fix:** Before writing any file, copy the original to `<filename>.backup` in the same directory.
- **Git-aware:** If the project is a git repo, check for uncommitted changes in the target files and warn if present ("You have uncommitted changes in 00_MASTER_PLAN.md — fix will overwrite them").
- **Concurrency:** All types are `Sendable`. File writes are sequential (one file at a time).
- **Safety:** No force unwraps. If a patch can't be applied cleanly (e.g., line numbers shifted), skip it and add to `unfixed`.

## 6. Backend Abstraction

**N/A** — file reading/writing + regex-based markdown patching.

## 7. Dependencies

**Internal:**
- `QualityGateCore` (protocol, models, new `FixableChecker` protocol)
- `StatusAuditor` (parsers, validators, collector)

**External:** None.

## 8. Test Strategy

### FixableChecker Protocol Tests

| Category | Fixture | Expected |
|----------|---------|----------|
| Fix with diagnostics | 3 diagnostics with fixable rules | FixResult with 3 modifications |
| Fix with unfixable diagnostics | 2 fixable + 1 unfixable | FixResult with 2 modifications, 1 unfixed |
| Fix with no diagnostics | Empty diagnostics array | FixResult with no changes |

### StatusRemediator Tests

| Category | Fixture | Expected |
|----------|---------|----------|
| Checkbox patch | `- [ ] SafetyAuditor — Stub only` + actual: 1186 lines | `- [x] SafetyAuditor — Code safety + security scanning (83 tests)` |
| Test count patch | `(54 tests)` + actual: 465 | `(465 tests)` |
| Phase label patch | `Phase 1: Foundation (CURRENT)` + all items checked | `Phase 1: Foundation (COMPLETE)` |
| Last Updated patch | `2026-01-01` + today is 2026-04-14 | `2026-04-14` |
| Preserve prose | Custom paragraph between sections | Paragraph unchanged after fix |
| Add missing module | Package.swift has RecursionAuditor, Master Plan doesn't | New entry added after last module |
| Remove phantom | Master Plan has FooChecker, Package.swift doesn't | Entry removed with note in unfixed |

### StatusBootstrapper Tests

| Category | Fixture | Expected |
|----------|---------|----------|
| Generate from scratch | Package.swift with 5 targets, 3 test targets | Complete Master Plan with 5 module entries |
| Empty project | Package.swift with 0 targets | Minimal Master Plan skeleton |

### Integration Tests

| Category | Fixture | Expected |
|----------|---------|----------|
| Full round-trip | Stale Master Plan → check → fix → re-check | Second check passes with 0 diagnostics |
| Dry-run doesn't write | Stale Master Plan → fix with dry-run | File unchanged, FixResult shows planned changes |
| Backup created | Fix applied | .backup file exists with original content |

**Reference truth:** Fixture-based — temporary directories with hand-authored Master Plans and Package.swift files.

## 9. Open Questions

- Should `--fix` require `--check status` or should it work as a standalone `quality-gate --fix`? **Proposed:** Require `--check` so only selected checkers apply fixes. `--fix` without `--check` runs all fixable checkers.
- Should `--bootstrap` be a subcommand (`quality-gate bootstrap`) or a flag? **Proposed:** flag on status checker (`--check status --bootstrap`). Subcommands are for future expansion.
- Should the backup use `.backup` extension or a timestamped name? **Proposed:** timestamped (`00_MASTER_PLAN.md.2026-04-14T09-30-00.backup`) to avoid overwriting previous backups.
- Should `FixableChecker` be a separate protocol or a method with default implementation on `QualityChecker`? **Proposed:** separate protocol. Most checkers are read-only — making fix optional via protocol conformance is cleaner than a default no-op.
- For the bootstrap case, should the generated Master Plan include placeholder sections for prose the developer should fill in? **Proposed:** yes — generate `<!-- TODO: Add project description -->` comments in narrative sections.

## 10. Documentation Strategy

**Documentation Type:** Narrative Article Required.

- 3+ APIs combined? Yes (FixableChecker, StatusRemediator, StatusBootstrapper, CLI flags).
- 50+ line explanation? Yes (remediation workflow, bootstrap vs. patch, dry-run, backup).
- Theory/background? Yes (why surgical patching matters, the dual-source problem).

**Article:** `StatusRemediationGuide.md` — covers the full remediation workflow:
1. Running `--check status` to see drift
2. Running `--check status --fix --dry-run` to preview patches
3. Running `--check status --fix` to apply patches
4. Running `--check status --bootstrap` for greenfield or severely drifted projects
5. Re-running `--check status` to verify zero drift

---

## User Journey: Existing Project Adoption

```
$ quality-gate --check status
✗ [status] FAILED (0.3s)
  ⚠ status.module-marked-incomplete: SafetyAuditor marked [ ] but has 1,186 lines (Sources/SafetyAuditor/)
  ⚠ status.stub-description-mismatch: SafetyAuditor described as "Stub only" but fully implemented
  ⚠ status.test-count-drift: Master Plan claims 54 tests, actual count is 465
  ⚠ status.roadmap-phase-stale: Phase 1 marked "CURRENT" but all items complete
  ⚠ status.last-updated-stale: Last updated 2026-01-15, 89 days ago
  ... (12 more diagnostics)

  💡 Run `quality-gate --check status --fix --dry-run` to preview auto-fixes.

$ quality-gate --check status --fix --dry-run
[status] Would apply 14 patches to 2 files:

  00_MASTER_PLAN.md:
    Line 97:  - [ ] SafetyAuditor — Stub only
           →  - [x] SafetyAuditor — Code safety + OWASP security scanning (83 tests)
    Line 98:  - [ ] BuildChecker — Stub only
           →  - [x] BuildChecker — swift build wrapper
    ...
    Line 172: **Last Updated:** 2026-01-15
           →  **Last Updated:** 2026-04-14

  04_IMPLEMENTATION_CHECKLIST.md:
    Line 49:  | SafetyAuditor | In Progress | 20 | Yes | 0 |
           →  | SafetyAuditor | Complete | 83 | Yes | 0 |

  No files modified (dry-run mode).

$ quality-gate --check status --fix
[status] Applied 14 patches to 2 files:
  ✓ 00_MASTER_PLAN.md — 12 patches (backup: 00_MASTER_PLAN.md.2026-04-14T09-30-00.backup)
  ✓ 04_IMPLEMENTATION_CHECKLIST.md — 2 patches (backup: ...)

$ quality-gate --check status
✓ [status] PASSED (0.3s)
```

### Greenfield / Severely Drifted Project

```
$ quality-gate --check status --bootstrap
[status] No Master Plan found. Generating from project state...
  ✓ Generated 00_MASTER_PLAN.md with 11 module entries
  ✓ Generated 04_IMPLEMENTATION_CHECKLIST.md with module status table
  ℹ  Review generated files and add project-specific prose where marked <!-- TODO -->
```

---

## Future Work (out of scope for v1)

- `FixableChecker` adoption by other checkers (e.g., DocCoverageChecker could add missing doc stubs)
- Interactive fix mode (`--fix --interactive`) that prompts per-patch
- PR-aware mode: generate a PR with the fixes instead of writing directly
- CHANGELOG generation from status changes
- Cross-project status: validate that development-guidelines template repo status matches all consuming projects
