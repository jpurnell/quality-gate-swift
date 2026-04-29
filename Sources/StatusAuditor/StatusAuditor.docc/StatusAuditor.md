# ``StatusAuditor``

Detects drift between project documentation and actual code state.

## Overview

StatusAuditor validates that a project's Master Plan (the "source of truth" markdown document) accurately reflects reality: which modules exist, which are complete, how many tests they have, and whether the roadmap is current. It parses the Master Plan's checkbox sections and roadmap phases, then cross-references them against the file system (Sources/, Tests/, Package.swift) to produce diagnostics for every provable inconsistency.

Unlike the syntax-based auditors (ConcurrencyAuditor, PointerEscapeAuditor), StatusAuditor operates on markdown documents and project structure rather than Swift ASTs. It is the only auditor that implements `FixableChecker` with full remediation support: `--fix` applies surgical line-level patches to the Master Plan, while `--bootstrap` generates a complete Master Plan from scratch when a project has no status documentation at all.

### Detected rules

| Rule ID | Severity | What it detects |
|---------|----------|-----------------|
| `status.module-marked-incomplete` | warning | Module has real code (above stub threshold) but checkbox says `[ ]` |
| `status.module-marked-complete-missing` | warning | Checkbox says `[x]` but module directory not found in Sources/ |
| `status.doc-doc-conflict` | warning | Master Plan and Implementation Checklist disagree on module status |
| `status.test-count-drift` | warning | Documented test count differs from actual by more than configured percentage |
| `status.stub-description-mismatch` | warning | Description says "Stub only" or "Not started" but module has real code |
| `status.roadmap-phase-stale` | warning | Phase marked "(CURRENT)" but all items in it are complete |
| `status.last-updated-stale` | warning | "Last Updated" date exceeds the configured staleness threshold |
| `status.phantom-module` | note | Module exists in Package.swift with real code but is not documented in Master Plan |

### FixableChecker support

StatusAuditor conforms to `FixableChecker`, enabling three modes of operation:

```bash
# Detect drift (default)
quality-gate --check status

# Preview fixes without writing (dry run)
quality-gate --check status --fix --dry-run

# Apply fixes with timestamped backup
quality-gate --check status --fix

# Generate a complete Master Plan from scratch
quality-gate --check status --bootstrap
```

**Auto-fixable rules** (patched in place by `--fix`):

- `status.module-marked-incomplete` -- flips `[ ]` to `[x]`
- `status.stub-description-mismatch` -- replaces "Stub only" / "Not started" with "Implemented"
- `status.test-count-drift` -- updates the `(N tests)` count in the description
- `status.roadmap-phase-stale` -- replaces `(CURRENT)` with `(COMPLETE)`
- `status.last-updated-stale` -- updates the date to today

**Human-judgment rules** (reported but never auto-fixed):

- `status.module-marked-complete-missing` -- may indicate a renamed or deleted module
- `status.phantom-module` -- may be intentionally undocumented
- `status.doc-doc-conflict` -- requires deciding which document is authoritative

All fixes create a timestamped `.backup` file before modifying the Master Plan. Human-authored prose is never altered.

### Configuration

StatusAuditor is configured via the `status` key in `.quality-gate.yml`:

```yaml
status:
  guidelinesPath: development-guidelines
  masterPlanPath: 00_CORE_RULES/00_MASTER_PLAN.md
  stubThresholdLines: 50
  testCountDriftPercent: 10
  lastUpdatedStaleDays: 90
```

| Key | Default | Description |
|-----|---------|-------------|
| `guidelinesPath` | `development-guidelines` | Path to the guidelines directory relative to project root |
| `masterPlanPath` | `00_CORE_RULES/00_MASTER_PLAN.md` | Path to Master Plan relative to the guidelines directory |
| `stubThresholdLines` | `50` | Minimum source lines to consider a module "implemented" (not a stub) |
| `testCountDriftPercent` | `10` | Maximum allowed percentage difference between documented and actual test counts |
| `lastUpdatedStaleDays` | `90` | Maximum days since "Last Updated" before flagging staleness |

### Architecture

StatusAuditor delegates to four internal components:

- **MasterPlanParser** -- Extracts `DocumentedModuleStatus` entries from the "What's Working" checkbox section, `DocumentedPhase` entries from the "## Roadmap" section, and the "Last Updated" date. Handles both em-dash and hyphen separators, and parses `(N tests)` counts from descriptions.

- **ProjectStateCollector** -- Walks Sources/, Tests/, Plugins/, and Package.swift to build a dictionary of `ActualModuleState` values. Counts Swift source files, total lines, test files, and estimates test counts by matching `@Test` attributes (Swift Testing) and `func test*` methods (XCTest).

- **StatusValidator** -- Cross-references documented state against actual state and emits diagnostics. Applies the `looksLikeModuleName` heuristic to avoid false positives on feature descriptions like "Job analysis via LLM" that appear in checkbox lists but are not SPM modules.

- **StatusRemediator** -- Consumes diagnostics and applies line-level patches to the Master Plan. Creates a timestamped backup before any modification. Only patches provably-wrong content.

- **StatusBootstrapper** -- Generates a complete Master Plan from actual project state when no status documentation exists. Inserts `<!-- TODO -->` placeholders where human-authored prose should be added.

### Out of scope

- Cross-repository status validation (each project validates its own Master Plan)
- Implementation Checklist generation (only Master Plan is currently parsed and patched)
- Semantic analysis of prose descriptions (only "Stub only" / "Not started" / "Not implemented" keywords are matched)
- Git history analysis to determine when modules were last modified
- Validating that documented dependencies match Package.swift dependency declarations

## Topics

### Essentials

- ``StatusAuditor/check(configuration:)``
- ``StatusAuditor/fix(diagnostics:configuration:)``

### Guides

- <doc:StatusAuditorGuide>
