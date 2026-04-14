# Design Proposal: MemoryBuilder Status Validation Enhancement

## 1. Objective

Add a validation pass to MemoryBuilder that detects inconsistencies between generated memory files and project status documents, ensuring that AI-consumed project state is always accurate. This complements the StatusAuditor (which validates docs-vs-code for humans) by validating memory-vs-code for AI agents.

**Master Plan Reference:** Phase 4 — Community & Polish (enhancement to existing MemoryBuilder)

**Motivation:** MemoryBuilder currently extracts project state and writes it to memory files, but never validates that previously-generated memory files still reflect reality. If a module is added but MemoryBuilder doesn't re-run, or if it runs but an extractor silently fails, the AI agent gets stale information. Combined with StatusAuditor, this creates a closed loop: StatusAuditor catches human-facing doc drift, MemoryBuilder validation catches AI-facing memory drift.

**Target validations:**
- Generated memory files claim module counts that don't match Package.swift
- Generated architecture memory references targets that no longer exist
- ActiveWorkExtractor's "recent commits" memory is >30 days old (stale context)
- ProjectProfileExtractor's dependency list doesn't match current Package.swift
- Generated test count in memory differs from actual test count by >10%
- Memory files reference CURRENT_*.md checklists that no longer exist
- ADR memory references decisions that have been superseded or removed
- MEMORY.md index has entries pointing to files that don't exist

## 2. Proposed Architecture

**No new module.** Extends existing MemoryBuilder with a post-extraction validation pass.

**New files:**
- `Sources/MemoryBuilder/Validators/MemoryValidator.swift` — Protocol and orchestrator
- `Sources/MemoryBuilder/Validators/ProjectProfileValidator.swift` — Validates profile memory against Package.swift
- `Sources/MemoryBuilder/Validators/ArchitectureValidator.swift` — Validates architecture memory against actual targets
- `Sources/MemoryBuilder/Validators/IndexValidator.swift` — Validates MEMORY.md links point to real files
- `Sources/MemoryBuilder/Validators/StalenessValidator.swift` — Checks generated-date freshness
- `Tests/MemoryBuilderTests/ValidatorTests.swift` — Tests for all validators

**Modified files:**
- `Sources/MemoryBuilder/MemoryBuilder.swift` — Add validation pass after extraction (line ~58)
- `Sources/QualityGateCore/Configuration.swift` — Add `memoryValidation: MemoryValidationConfig` with staleness thresholds

## 3. API Surface

```swift
/// Protocol for memory file validators.
protocol MemoryValidator {
    /// Validates generated memory against current project state.
    func validate(
        memoryDirectory: URL,
        projectRoot: URL,
        configuration: Configuration
    ) throws -> [Diagnostic]
}

/// Configuration for memory validation thresholds.
public struct MemoryValidationConfig: Sendable, Codable, Equatable {
    /// Maximum days since memory generation before flagging staleness.
    public let staleAfterDays: Int

    /// Maximum allowed percentage difference between memory and actual values.
    public let driftThresholdPercent: Int

    /// Whether to validate MEMORY.md index links.
    public let validateIndex: Bool

    public static let `default`: MemoryValidationConfig
}
```

`Diagnostic.ruleId` values:
- `memory.profile-drift` — ProjectProfile memory doesn't match Package.swift
- `memory.architecture-drift` — Architecture memory references non-existent targets
- `memory.stale-generation` — Memory file generated >N days ago
- `memory.broken-index-link` — MEMORY.md entry points to non-existent file
- `memory.stale-checklist-ref` — Memory references CURRENT_*.md that doesn't exist
- `memory.test-count-drift` — Memory claims N tests but actual count differs significantly

## 4. MCP Schema

**N/A.** Internal to MemoryBuilder checker. Runs via `--check memory-builder`.

## 5. Constraints & Compliance

- **Concurrency:** Validators are value types, `Sendable`.
- **Safety:** No force unwraps. Missing files produce skip diagnostics, not crashes.
- **Non-destructive:** Validation only reads memory files. Never modifies them — that's the extraction pass's job.
- **Ordering:** Validation runs AFTER extraction, so newly-generated files are validated against current state. This catches extractor bugs.
- **Backwards compatible:** If no memory directory exists, validation silently skips (no failure).

## 6. Backend Abstraction

**N/A** — file reading + string parsing.

## 7. Dependencies

**Internal:**
- `QualityGateCore` (protocol, models)
- Existing MemoryBuilder extractors (for re-reading Package.swift state)

**External:** None new.

## 8. Test Strategy

**Test categories:**

| Category | Fixture | Expected |
|----------|---------|----------|
| Profile drift | Memory says "3 targets", Package.swift has 5 | `memory.profile-drift` |
| Architecture drift | Memory references "FooModule", not in Package.swift | `memory.architecture-drift` |
| Stale generation | Memory `generated-by` date >30 days ago | `memory.stale-generation` |
| Broken index link | MEMORY.md: `[Foo](foo.md)`, foo.md doesn't exist | `memory.broken-index-link` |
| All valid | Memory matches reality | No diagnostics |
| No memory directory | Fresh project, no `.claude/` | Skip gracefully |

**Reference truth:** Fixture-based — create temp directories with memory files and Package.swift, run validators.

## 9. Open Questions

- Should validation run on every `--check memory-builder` invocation or only with `--validate` flag? **Proposed:** always run — it's cheap and catches problems early.
- Should stale memory files be auto-regenerated or just flagged? **Proposed:** flag only in validation pass; regeneration is the extraction pass's job.
- How do we get actual test counts without running `swift test`? **Proposed:** count `@Test` and `func test` occurrences in test files (fast heuristic, not exact but catches 10x drift).

## 10. Documentation Strategy

**Documentation Type:** API Docs Only (extend MemoryBuilder's DocC catalog).

- 3+ APIs combined? No (internal validators).
- 50+ line explanation? No.
- Theory/background? No.

---

## Interaction with StatusAuditor

These two checkers form a closed validation loop:

```
                    ┌─────────────────────────┐
                    │     Actual Code State    │
                    │  (Sources/, Tests/,      │
                    │   Package.swift)         │
                    └────────┬────────────────┘
                             │
               ┌─────────────┼─────────────┐
               ▼                           ▼
    ┌──────────────────┐        ┌──────────────────┐
    │  Status Documents │        │  Memory Files    │
    │  (Master Plan,   │        │  (.claude/memory/)│
    │   Checklist)     │        │                  │
    └────────┬─────────┘        └────────┬─────────┘
             │                           │
             ▼                           ▼
    ┌──────────────────┐        ┌──────────────────┐
    │  StatusAuditor    │        │  MemoryBuilder   │
    │  (human-facing)   │        │  Validation      │
    │                  │        │  (AI-facing)     │
    └──────────────────┘        └──────────────────┘
```

StatusAuditor validates that human-readable docs match code.
MemoryBuilder validation ensures that AI-readable memory matches code.
Together, no representation of project state can silently drift.

---

## Future Work (out of scope for v1)

- Cross-validate StatusAuditor findings against MemoryBuilder findings
- Auto-regenerate stale memory files when drift is detected
- Track memory accuracy over time (did the last generation introduce drift?)
- Validate memory files against CI test results (exact counts from SARIF output)
