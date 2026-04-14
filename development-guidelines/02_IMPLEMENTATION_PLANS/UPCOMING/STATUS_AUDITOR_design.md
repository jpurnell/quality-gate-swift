# Design Proposal: StatusAuditor — Documentation Drift Detector

## 1. Objective

Catch documentation-reality drift in project status documents before it reaches production. Inspired by a real incident where the Master Plan declared 6 modules as "Stub only" for months while all were fully implemented with hundreds of tests — discovered only during a public repo quality audit.

**Master Plan Reference:** Phase 4 — Community & Polish (new checker in the quality-gate family)

**The problem has three layers:**
1. **Code vs. docs drift:** Master Plan says "Stub only" but `Sources/SafetyAuditor/` has 1,186 lines and 83 tests
2. **Doc vs. doc drift:** Master Plan and Implementation Checklist track module status independently with no sync enforcement
3. **Weak workflow rule:** Session Workflow says "update Master Plan if architecture changed" — but completing a module isn't an architecture change, so the rule never fires

**Target patterns:**
- Master Plan `- [ ]` (incomplete) checkbox for a module that has >N lines of source code and >0 tests
- Master Plan `- [x]` (complete) checkbox for a module whose directory doesn't exist or has 0 source files
- Master Plan module status that conflicts with Implementation Checklist module status
- Master Plan test counts that differ from actual `swift test` results by >10%
- Master Plan "Stub only" or "Not started" text for modules with real implementations
- Roadmap phase marked "CURRENT" when all its items are checked complete
- Roadmap items that reference modules not in Package.swift
- "Last Updated" date >90 days old when code has changed since that date

## 2. Proposed Architecture

**New module:** `Sources/StatusAuditor/`

**New files:**
- `Sources/StatusAuditor/StatusAuditor.swift` — Public `QualityChecker` entry point
- `Sources/StatusAuditor/MasterPlanParser.swift` — Parses checkbox status, module descriptions, roadmap phases, test counts from Master Plan markdown
- `Sources/StatusAuditor/ChecklistParser.swift` — Parses Implementation Checklist module status table
- `Sources/StatusAuditor/ProjectStateCollector.swift` — Collects actual module state: source line counts, test counts, file existence
- `Sources/StatusAuditor/StatusValidator.swift` — Cross-validates parsed docs against collected state

**New tests:** `Tests/StatusAuditorTests/` with fixture-based tests.

**Modified files:**
- `Package.swift` — register `StatusAuditor` target + test target, add to `QualityGateCLI` deps
- `Sources/QualityGateCLI/QualityGateCLI.swift` — register checker
- `Sources/QualityGateCore/Configuration.swift` — add `status: StatusAuditorConfig` config block

## 3. API Surface

```swift
public struct StatusAuditor: QualityChecker, Sendable {
    public let id = "status"
    public let name = "Status Auditor"

    public init() {}

    public func check(configuration: Configuration) async throws -> CheckResult
}

/// Parsed state of a module from documentation.
public struct DocumentedModuleStatus: Sendable {
    public let name: String
    public let isComplete: Bool         // from checkbox [x] vs [ ]
    public let description: String      // e.g. "Stub only", "Protocol, models, reporters (54 tests)"
    public let claimedTestCount: Int?   // parsed from description if present
    public let source: String           // "master-plan" or "checklist"
}

/// Actual state of a module from the file system.
public struct ActualModuleState: Sendable {
    public let name: String
    public let sourceFileCount: Int
    public let sourceLineCount: Int
    public let testFileCount: Int
    public let existsInPackageSwift: Bool
}

public struct StatusAuditorConfig: Sendable, Codable, Equatable {
    /// Path to Master Plan relative to project root.
    public let masterPlanPath: String

    /// Path to Implementation Checklist relative to project root.
    public let checklistPath: String

    /// Minimum source lines to consider a module "implemented" (not a stub).
    public let stubThresholdLines: Int

    /// Maximum allowed percentage difference between documented and actual test counts.
    public let testCountDriftPercent: Int

    /// Maximum days since "Last Updated" before flagging staleness.
    public let lastUpdatedStaleDays: Int

    public static let `default`: StatusAuditorConfig
}
```

`Diagnostic.ruleId` values:
- `status.module-marked-incomplete` — Module has real code but checkbox says `[ ]`
- `status.module-marked-complete-missing` — Checkbox says `[x]` but module doesn't exist
- `status.doc-doc-conflict` — Master Plan and Checklist disagree on module status
- `status.test-count-drift` — Documented test count differs from actual by >threshold
- `status.stub-description-mismatch` — Description says "Stub only" but module has real code
- `status.roadmap-phase-stale` — Phase marked "CURRENT" but all items checked
- `status.last-updated-stale` — "Last Updated" date exceeds staleness threshold
- `status.phantom-module` — Roadmap references a module not in Package.swift

## 4. MCP Schema

**N/A.** CLI/SPM plugin checker. Umbrella `quality-gate` MCP description lists `status` as one of its checkers.

## 5. Constraints & Compliance

- **Concurrency:** `StatusAuditor` is a value type and `Sendable`. File system reads are synchronous (small files).
- **Safety:** No force unwraps. Guard clauses for all parsing. Graceful degradation if docs don't exist (skip, don't crash).
- **No false positives over false negatives:** When in doubt about parsing ambiguity, do NOT flag. Only flag clear contradictions.
- **Plugin parity:** Same `QualityChecker` protocol, same `Diagnostic` model, same reporters.
- **Graceful absence:** If Master Plan or Checklist doesn't exist, emit a note and skip (not all projects use these docs).

## 6. Backend Abstraction

**N/A** — markdown parsing + file system stat calls. CPU-only.

## 7. Dependencies

**Internal:**
- `QualityGateCore` (protocol, models)

**External:** None. Markdown parsing is regex-based (no external parser needed for structured sections like checkboxes and tables).

## 8. Test Strategy

**Test categories:**

| Category | Fixture | Expected |
|----------|---------|----------|
| Module marked incomplete but implemented | Master Plan: `- [ ] SafetyAuditor — Stub only`, Sources/SafetyAuditor/ has 500+ lines | `status.module-marked-incomplete` + `status.stub-description-mismatch` |
| Module marked complete but missing | Master Plan: `- [x] FooChecker — Complete`, no Sources/FooChecker/ | `status.module-marked-complete-missing` |
| Doc-doc conflict | Master Plan: `- [x] TestRunner`, Checklist: TestRunner status "In Progress" | `status.doc-doc-conflict` |
| Test count drift | Master Plan: "(54 tests)", actual: 465 tests | `status.test-count-drift` |
| All correct | Master Plan matches reality | No diagnostics, status `.passed` |
| Missing Master Plan | No Master Plan file | Note diagnostic, status `.passed` |
| Stale roadmap phase | Phase 1 marked "CURRENT", all items `[x]` | `status.roadmap-phase-stale` |
| Last Updated stale | "Last Updated: 2026-01-01", today is 2026-04-14 | `status.last-updated-stale` |

**Reference truth:** Hand-authored markdown fixtures + temporary directory structures.

## 9. Open Questions

- Should the checker also validate that `CLAUDE.md` references to development-guidelines paths actually exist? **Proposed:** yes, as a bonus rule, low priority.
- Should test count comparison use `swift test --list-tests` or just count test files? **Proposed:** count test files for speed; exact test counts require a build which is expensive. The MemoryBuilder enhancement (see companion proposal) can provide cached test counts.
- Should this checker run in the default set or require opt-in? **Proposed:** opt-in initially (`--check status`), promoted to default after stabilization.

## 10. Documentation Strategy

**Documentation Type:** API Docs + short narrative article.

- 3+ APIs combined? Yes (parser + collector + validator).
- 50+ line explanation? Yes (the drift problem and how to interpret diagnostics).
- Theory/background? Minimal.

Article: `StatusDriftGuide.md` — explains the three layers of drift, how to interpret diagnostics, and how to fix them.

---

## Future Work (out of scope for v1)

- Parse and validate `CHANGELOG.md` against git tags
- Validate that README feature claims match actual checker registrations in CLI
- Track status changes over time (git blame integration)
- Auto-fix: generate correct Master Plan content from actual state
