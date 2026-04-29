# StatusAuditor Guide

A practical walkthrough of every StatusAuditor rule, with the drift pattern it catches and the recommended remediation.

## Why this auditor exists

Documentation and reality drift apart. It happens on every project, and it happens faster than anyone expects.

A module gets renamed but the Master Plan still lists the old name. A feature ships 200 tests but the docs still say "42 tests". A roadmap phase marked "(CURRENT)" has been fully complete for three sprints. A new module appears in Package.swift but nobody adds it to the status section.

None of these are bugs in the code. All of them are bugs in the project's ability to reason about itself. When an AI agent or a new team member reads the Master Plan to understand what exists and what's done, stale documentation produces wrong decisions: re-implementing something that already works, skipping a module that's actually incomplete, or planning against a roadmap that no longer reflects reality.

StatusAuditor closes this loop by treating the Master Plan as a testable artifact. It parses the documented state, collects the actual state from the file system, and emits a diagnostic for every provable inconsistency.

## Rule walkthrough

### `status.module-marked-incomplete`

The Master Plan checkbox says `[ ]` (incomplete) but the module has real source code above the stub threshold (default: 50 lines).

```markdown
<!-- Master Plan says: -->
- [ ] SafetyAuditor -- Code safety + OWASP security (83 tests)

<!-- But Sources/SafetyAuditor/ contains 2,400 lines of Swift across 15 files -->
```

This is the most common drift pattern. It happens when developers implement a module but forget to update the status document afterward.

**Auto-fix:** `--fix` flips the checkbox to `[x]`.

**False positive risk:** Low. If a module genuinely has 50+ lines but is not considered "complete" by project standards, increase `stubThresholdLines` in configuration. The threshold is intentionally low because even a 50-line module is no longer a stub.

### `status.module-marked-complete-missing`

The Master Plan checkbox says `[x]` (complete) but no directory exists under Sources/ with that name.

```markdown
<!-- Master Plan says: -->
- [x] OldReporter -- JSON + terminal output

<!-- But Sources/OldReporter/ does not exist (was renamed to Reporter) -->
```

This happens after module renames, deletions, or repository reorganizations. It can also fire if a "What's Working" entry is a feature description rather than an SPM module name. The auditor applies a `looksLikeModuleName` heuristic to reduce noise: entries containing spaces, punctuation, or sentence fragments (like "Job analysis via LLM" or "Docker + Redis") are not flagged.

**Not auto-fixable.** The auditor cannot determine whether the module was renamed, deleted, or is a feature description. Human judgment required: remove the entry, rename it to match the new module name, or restructure the entry so it does not look like an SPM target.

### `status.doc-doc-conflict`

The Master Plan and the Implementation Checklist disagree on a module's completion status.

```markdown
<!-- Master Plan says: -->
- [x] FooChecker -- Complete

<!-- Implementation Checklist says: -->
- [ ] FooChecker -- Phase 2 items remaining
```

This happens when one document is updated but the other is not. It is particularly dangerous because different team members (or AI agents) may consult different documents and reach contradictory conclusions about project state.

**Not auto-fixable.** The auditor cannot determine which document is authoritative. Review both and update the incorrect one.

### `status.test-count-drift`

The documented test count differs from the actual count by more than the configured threshold (default: 10%).

```markdown
<!-- Master Plan says: -->
- [x] SafetyAuditor -- Code safety + OWASP security (42 tests)

<!-- But Tests/SafetyAuditorTests/ contains approximately 83 @Test or func test* occurrences -->
```

The actual count is estimated by scanning test files for `@Test` attributes (Swift Testing framework) and `func test*` method signatures (XCTest). This is a heuristic, not an exact count -- parameterized tests, disabled tests, and helper methods named `testHelper*` may cause slight inaccuracy.

**Auto-fix:** `--fix` updates the parenthetical count to match the estimated actual count, e.g., `(42 tests)` becomes `(83 tests)`.

**False positive risk:** Moderate. If the documented count reflects a deliberate "target" rather than the current state, or if parameterized tests inflate the estimate, this rule will fire. Increase `testCountDriftPercent` to widen the tolerance.

### `status.stub-description-mismatch`

The description text contains "Stub only", "Not started", or "Not implemented" but the module has real source code above the stub threshold.

```markdown
<!-- Master Plan says: -->
- [ ] RecursionAuditor -- Stub only

<!-- But Sources/RecursionAuditor/ contains 800 lines across 5 files -->
```

This is a special case of documentation drift where both the checkbox *and* the description are stale. The module was implemented but the description was never updated.

**Auto-fix:** `--fix` replaces "Stub only" / "Not started" / "Not implemented" with "Implemented" in the description text. The checkbox fix is handled separately by `status.module-marked-incomplete`.

### `status.roadmap-phase-stale`

A roadmap phase heading is labeled `(CURRENT)` but every checkbox item in that phase is marked `[x]`.

```markdown
### Phase 2: Checker Modules (CURRENT)

- [x] SafetyAuditor
- [x] BuildChecker
- [x] TestRunner
- [x] DocLinter
```

This means the team has completed a phase but not updated the roadmap to reflect progress. Downstream consumers of the roadmap (including AI agents planning next steps) will incorrectly believe this phase still has open work.

**Auto-fix:** `--fix` replaces `(CURRENT)` with `(COMPLETE)` in the phase heading.

**Note:** The auditor does not attempt to determine which phase *should* become the new `(CURRENT)`. That requires human judgment about project priorities.

### `status.last-updated-stale`

The "Last Updated" date in the Master Plan is older than the configured threshold (default: 90 days).

```markdown
**Last Updated:** 2025-11-15

<!-- Today is 2026-04-29 -- 165 days ago, well past the 90-day threshold -->
```

A stale "Last Updated" date does not mean the content is wrong, but it is a strong signal that the document has not been reviewed recently. For projects under active development, 90+ days without a review almost certainly means some content has drifted.

**Auto-fix:** `--fix` updates the date to today's date in ISO 8601 format (YYYY-MM-DD).

**False positive risk:** Low for active projects. For archived or stable projects, increase `lastUpdatedStaleDays` or disable the rule by removing the "Last Updated" line from the Master Plan.

### `status.phantom-module`

A module exists in Package.swift with real source code above the stub threshold but does not appear anywhere in the Master Plan's "What's Working" section.

```markdown
<!-- Package.swift defines: -->
.target(name: "LoggingAuditor", ...)

<!-- Sources/LoggingAuditor/ has 450 lines -->

<!-- But the Master Plan's "What's Working" section has no entry for LoggingAuditor -->
```

This happens when a new module is added to the project but the developer does not update the Master Plan. The module is invisible to anyone reading the documentation.

Test targets (names ending in "Tests") and plugin targets (names ending in "Plugin") are automatically excluded from this rule.

**Not auto-fixable.** The auditor does not know where in the document the entry should go, what description to use, or whether the module is intentionally undocumented (perhaps it is an internal implementation detail). The suggested fix in the diagnostic is `Add entry: - [x] ModuleName`.

## Remediation workflow

### Detect

Run the auditor in detect-only mode to see all drift:

```bash
quality-gate --check status
```

The output lists every diagnostic with its rule ID, the affected file and line number, and a suggested fix.

### Preview

Before applying fixes, preview what would change:

```bash
quality-gate --check status --fix --dry-run
```

This shows every line that would be modified without writing any files.

### Fix

Apply all auto-fixable patches:

```bash
quality-gate --check status --fix
```

The auditor creates a timestamped backup (e.g., `00_MASTER_PLAN.md.2026-04-29T14-30-00Z.backup`) before modifying any file. Human-authored prose, section structure, and non-status content are never altered.

After fixing, review the remaining unfixed diagnostics (the human-judgment rules) and address them manually.

### Bootstrap

For projects that have no Master Plan at all, or where drift is so severe that patching would be worse than starting fresh:

```bash
quality-gate --check status --bootstrap
```

This generates a complete Master Plan by scanning Sources/, Tests/, and Package.swift. The generated document includes:

- A "What's Working" section with a checkbox entry for every non-test, non-plugin target
- Source file counts, line counts, and estimated test counts for each module
- A single-phase roadmap with all modules listed
- `<!-- TODO -->` placeholders where human-authored prose should be added
- Today's date as the "Last Updated" value

The generated Master Plan is a starting point, not a finished document. Review it, organize the roadmap into meaningful phases, add project context, and customize descriptions.

## False positives

StatusAuditor is deliberately conservative. Every diagnostic represents a provable inconsistency between the document and the file system. The main sources of noise are:

- **Feature descriptions in checkbox lists.** The "What's Working" section sometimes contains entries like "Job description analysis via LLM" that are feature descriptions, not SPM module names. The `looksLikeModuleName` heuristic filters most of these out (entries with spaces, punctuation, or sentence structure are skipped), but unusual naming may occasionally slip through.

- **Test count estimation.** The heuristic counts `@Test` and `func test*` occurrences, which may overcount (parameterized test helper methods) or undercount (test cases generated at runtime). Widen `testCountDriftPercent` if the estimates are consistently off for your project.

- **Intentionally undocumented modules.** Internal implementation-detail modules that are not meant to appear in the Master Plan will trigger `status.phantom-module`. These are emitted at `note` severity, not `warning`, so they do not cause the check to fail.

If a rule is consistently unhelpful for your project, adjust the corresponding threshold in `.quality-gate.yml` rather than ignoring the output. Ignored warnings erode trust in the gate.
