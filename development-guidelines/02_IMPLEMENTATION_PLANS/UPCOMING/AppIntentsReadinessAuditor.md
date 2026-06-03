# Design Proposal: App Intents Readiness Auditor

**Status:** PROPOSAL
**Date:** 2026-06-02
**Author:** jpurnell + Claude

---

## 1. Objective

Add a quality-gate checker that audits Apple App Intents declarations for completeness, discoverability, and Apple Intelligence readiness. Ensures that apps exposing functionality through Siri, Shortcuts, Spotlight, and Apple Intelligence do so correctly, completely, and with first-class AI integration.

**Master Plan Reference:** Extends the quality-gate auditor family alongside existing MCP Readiness Auditor. Where MCP readiness ensures machine-consumable tool schemas are correct for Claude and other LLMs, App Intents readiness ensures Apple's on-device AI integration layer is correct for Apple Intelligence. Both checkers enforce the same principle: if your app exposes capabilities to an AI system, the metadata must be complete enough for that system to use them well.

## 2. Motivation

**Current situation:** App Intents are a compile-time framework -- the compiler checks protocol conformance but does not validate semantic completeness. A struct can conform to `AppIntent` with a title and `perform()` but omit descriptions, parameter titles, entity queries, `@AssistantIntent` annotations, or `AppShortcutsProvider` registration. The result compiles but is invisible to Siri/Shortcuts, produces poor Apple Intelligence results, or silently degrades the user experience.

**Workaround:** Developers manually review intent declarations against Apple's documentation checklist. This is error-prone, not enforced, and especially unreliable for the newer Apple Intelligence annotations (`@AssistantIntent`, `@AssistantEnum`, `@AssistantEntity`) that developers may not even know about.

**Drawback:** Missing descriptions degrade Apple Intelligence's ability to select the right intent. Missing `@AssistantIntent` schemas mean Apple Intelligence cannot invoke the intent at all. Missing `AppShortcutsProvider` means intents don't appear in Shortcuts until the user discovers them. Missing entity queries break parameter resolution. These are all silent failures -- the app works, but the integration surface is incomplete. With Apple Intelligence becoming the primary discovery mechanism for app capabilities, these gaps have direct user-facing consequences.

## 3. Proposed Architecture

### Two-Pass Analysis

The checker uses a two-pass architecture to balance speed with cross-file accuracy:

**Pass 1: Per-file AST analysis (always runs)**
Fast SwiftSyntax walk of each file containing `import AppIntents`. Detects intents, entities, enums, and shortcuts providers declared with explicit conformance in the same file. Catches ~90% of cases with zero external dependencies beyond SwiftSyntax.

**Pass 2: IndexStoreDB cross-file analysis (runs when index store is available)**
Queries the compiler's index store (produced by `swift build`) for resolved protocol conformances across all files and modules. Catches intents declared in one file with conformance added via extension in another. Falls back gracefully if the index store is stale or missing -- the quality-gate `[build]` check runs first, so the index is typically fresh.

This mirrors UnreachableCodeAuditor's architecture: a fast syntactic pass for immediate results, with an optional index-backed pass for cross-file precision.

**New Files:**
- `Sources/IndexStoreInfra/IndexStoreInfra.swift` -- Shared IndexStoreDB infrastructure (extracted from UnreachableCodeAuditor)
- `Sources/IndexStoreInfra/StoreLocator.swift` -- Locates index store in SPM `.build/` or Xcode DerivedData
- `Sources/IndexStoreInfra/ConformanceQuery.swift` -- Query helpers for protocol conformance resolution
- `Tests/IndexStoreInfraTests/IndexStoreInfraTests.swift`
- `Sources/AppIntentsAuditor/AppIntentsAuditor.swift` -- Main checker, conforms to `QualityChecker`, orchestrates both passes
- `Sources/AppIntentsAuditor/AppIntentVisitor.swift` -- SwiftSyntax visitor for `AppIntent`, `AppEntity`, `AppEnum`, `AppShortcutsProvider`
- `Sources/AppIntentsAuditor/IntentIndexPass.swift` -- IndexStoreDB pass for cross-file conformance resolution
- `Sources/AppIntentsAuditor/ExtractedTypes.swift` -- Shared extracted type definitions (intents, entities, enums, parameters)
- `Tests/AppIntentsAuditorTests/AppIntentsAuditorTests.swift`
- `Tests/AppIntentsAuditorTests/AppIntentVisitorTests.swift`
- `Tests/AppIntentsAuditorTests/IntentIndexPassTests.swift`

**Modified Files:**
- `Sources/UnreachableCodeAuditor/IndexStoreManager.swift` -- Extract to `IndexStoreInfra`, replace with thin import wrapper
- `Sources/UnreachableCodeAuditor/IndexStorePass.swift` -- Update imports to use `IndexStoreInfra`
- `Sources/QualityGateCore/Configuration.swift` -- Add `AppIntentsConfig` struct
- `Sources/QualityGateCLI/QualityGateCLI.swift` -- Register `AppIntentsAuditor()` in `allCheckers`
- `Package.swift` -- Add `IndexStoreInfra`, `AppIntentsAuditor` targets + test targets + library products; update UnreachableCodeAuditor dependency

**Documentation Deliverables:**
- `Sources/IndexStoreInfra/IndexStoreInfra.docc/IndexStoreInfraGuide.md` -- Narrative article explaining what IndexStoreDB unlocks for cross-file analysis, the shared API surface, upgrade roadmap for all checkers, and how to build new checkers on top of it
- `Sources/AppIntentsAuditor/AppIntentsAuditor.docc/AppIntentsGuide.md` -- Narrative article explaining what the checker does, why Apple Intelligence integration matters, and how to resolve each diagnostic
- Blog post (separate from source tree) -- Product announcement covering both the new checker and IndexStoreInfra as shared infrastructure

**Module Placement:** `AppIntentsAuditor/` -- follows the established pattern of one SPM target per checker (MCPReadinessAuditor, HIGAuditor, etc.)

## 4. API Surface

### Checker

```swift
public struct AppIntentsAuditor: QualityChecker, Sendable {
    public let id = "appintents-readiness"
    public let name = "App Intents Readiness Auditor"

    public init() {}

    public func check(configuration: Configuration) async throws -> CheckResult
}
```

### Configuration

```swift
public struct AppIntentsConfig: Sendable, Equatable, Codable {
    /// Whether the checker is enabled.
    public let enabled: Bool                    // default: false

    /// Minimum character length for intent and parameter descriptions.
    public let minDescriptionLength: Int         // default: 10

    /// Source directories to exclude from scanning.
    public let excludePaths: [String]            // default: []

    /// Whether to require AppShortcutsProvider when intents exist.
    public let requireShortcutsProvider: Bool     // default: true

    /// Whether to audit AppEntity conformances for queries and display.
    public let auditEntities: Bool               // default: true

    /// Whether to audit AppEnum conformances for display and assistant annotations.
    public let auditEnums: Bool                  // default: true

    /// Whether to use IndexStoreDB for cross-file conformance resolution.
    public let useIndexStore: Bool               // default: true
}
```

### YAML Configuration

```yaml
appIntentsReadiness:
  enabled: true
  minDescriptionLength: 10
  excludePaths: []
  requireShortcutsProvider: true
  auditEntities: true
  auditEnums: true
  useIndexStore: true
```

### Detected Rules

#### Intent Completeness
- `appintent-no-description` (warning) -- `AppIntent` struct missing `IntentDescription`
- `appintent-description-too-short` (note) -- Description under minimum character length
- `appintent-param-no-title` (warning) -- `@Parameter` property wrapper missing `title:` argument
- `appintent-no-perform` (error) -- `AppIntent` conformer without `perform()` method

#### Entity Completeness
- `appintent-entity-no-query` (warning) -- `AppEntity` without an associated `EntityQuery` type
- `appintent-entity-no-display` (warning) -- `AppEntity` missing `displayRepresentation` property
- `appintent-entity-no-id` (warning) -- `AppEntity` missing `id` property
- `appintent-entity-no-type-display` (warning) -- `AppEntity` missing `typeDisplayRepresentation` static property

#### Enum Completeness
- `appintent-enum-no-display` (warning) -- `AppEnum` missing `typeDisplayRepresentation`
- `appintent-enum-case-no-display` (warning) -- `AppEnum` case not represented in `caseDisplayRepresentations`
- `appintent-enum-not-assistant` (warning) -- `AppEnum` used as parameter type but not annotated with `@AssistantEnum`

#### Discoverability
- `appintent-no-shortcuts-provider` (warning) -- Project has intents but no `AppShortcutsProvider` conformer
- `appintent-shortcut-no-phrases` (warning) -- `AppShortcutsProvider` with empty `appShortcuts` array

#### Apple Intelligence Readiness
- `appintent-no-assistant-schema` (warning) -- Intent missing `@AssistantIntent` annotation
- `appintent-entity-not-assistant` (warning) -- `AppEntity` not annotated with `@AssistantEntity`
- `appintent-no-intent-description` (warning) -- Intent lacks `IntentDescription` with `searchKeywords` for Spotlight integration

#### Cross-File (IndexStoreDB pass)
- `appintent-conformance-split` (note) -- Intent conformance declared via extension in a different file (informational -- not an error, but flagged for awareness)
- `appintent-orphan-entity` (note) -- `AppEntity` defined but never referenced as a parameter type in any intent

## 5. MCP Schema

N/A -- This is a quality-gate checker, not an MCP tool. It runs as a build-time auditor.

## 6. Constraints & Compliance

- **Concurrency:** All types are `Sendable` (immutable structs, `SyntaxVisitor` is `final class` per SwiftSyntax convention)
- **SwiftSyntax:** Uses AST-based analysis, not string matching. Same approach as MCPReadinessAuditor, RecursionAuditor, ConcurrencyAuditor
- **IndexStoreDB:** Optional cross-file pass reuses the same `indexstore-db` dependency and index store location logic that UnreachableCodeAuditor already uses. Can share `IndexStoreManager` infrastructure
- **Skip logic:** Returns `.skipped` if no files in `Sources/` contain `import AppIntents` -- libraries and CLI tools pay zero cost
- **No AppIntents framework dependency:** The checker parses source text with SwiftSyntax and queries the index store with IndexStoreDB. It does not import or link against the AppIntents framework itself. Runs on macOS; Linux support limited to AST-only pass (index store is Apple-toolchain-specific)
- **Safety:** No force unwraps, no force casts, guard-based early returns
- **Apple Intelligence first-class:** Missing `@AssistantIntent`, `@AssistantEnum`, and `@AssistantEntity` annotations are warnings, not notes. The checker treats Apple Intelligence integration as expected, not optional

## 7. Source & API Compatibility

**Breaking changes:** None -- entirely new module with no existing API surface.
**Incremental adoption:** Projects opt in via `.quality-gate.yml` configuration. Defaults to skipping when no `import AppIntents` is found.

## 8. Backend Abstraction

N/A -- not compute-intensive. The AST pass is single-threaded per file. The IndexStoreDB pass is a set of queries against an existing database, not a computation.

## 9. Dependencies

**Internal Dependencies:**
- `QualityGateCore` -- `QualityChecker` protocol, `CheckResult`, `Diagnostic`, `Configuration`
- `SwiftSyntax` + `SwiftParser` -- AST parsing and visitor pattern
- `IndexStoreInfra` (new shared module) -- Index store location, staleness checking, conformance queries

**External Dependencies:** None new. All dependencies already exist in the project.

**Shared Infrastructure -- IndexStoreInfra:**

The `IndexStoreManager` currently lives inside `UnreachableCodeAuditor` as private infrastructure. This proposal extracts it into a new `IndexStoreInfra` module that provides:

1. **StoreLocator** -- Finds the index store in SPM `.build/debug/index/store`, Xcode DerivedData, or a user-specified path. Checks staleness against source file modification times. Locates `libIndexStore.dylib`.

2. **ConformanceQuery** -- High-level queries: "find all types conforming to protocol X", "find all extensions of type Y", "find all references to symbol Z". Wraps IndexStoreDB's raw symbol/occurrence API into checker-friendly operations.

3. **SymbolGraph** -- Lightweight in-memory graph of symbol relationships (caller/callee, conformer/protocol, container/member) built from index store data. Shared across checkers that need relational queries.

This enables a growing set of checkers to leverage cross-file analysis without each one reimplementing index store plumbing:

| Checker | IndexStoreInfra Usage |
|---|---|
| **UnreachableCodeAuditor** | Already uses it (extraction, not new behavior) |
| **AppIntentsAuditor** | Cross-file conformance, orphan entity detection |
| **MCPReadinessAuditor** | Cross-file tool/schema correlation (future) |
| **RecursionAuditor** | Cross-file mutual recursion detection (future) |
| **DocCoverageChecker** | APIs added via extension in other files (future) |
| **ComplexityAnalyzer** | Cross-file call chain cost propagation (future) |
| **ConcurrencyAuditor** | Cross-file actor isolation verification (future) |
| **TestQualityAuditor** | Test coverage of public API surface (future) |

Future capabilities enabled by having shared index infrastructure:
- **Dead protocol detection** -- protocols defined but never conformed to
- **Module boundary analysis** -- types crossing module boundaries
- **Unused import detection** -- `import Foo` where no Foo symbols are referenced

## 10. Test Strategy

**Test Categories:**

- **Golden path:** Well-formed `AppIntent` with title, description, `@AssistantIntent`, parameters with titles, perform() -- passes clean
- **Missing description:** `AppIntent` with title but no `IntentDescription` -- emits `appintent-no-description`
- **Missing parameter title:** `@Parameter var name: String` without `title:` -- emits `appintent-param-no-title`
- **Missing assistant annotation:** `AppIntent` without `@AssistantIntent` -- emits `appintent-no-assistant-schema`
- **Entity without query:** `AppEntity` conformer missing `EntityQuery` -- emits `appintent-entity-no-query`
- **Entity without display:** `AppEntity` missing `displayRepresentation` -- emits `appintent-entity-no-display`
- **Entity without assistant:** `AppEntity` without `@AssistantEntity` -- emits `appintent-entity-not-assistant`
- **Enum without display:** `AppEnum` missing `typeDisplayRepresentation` -- emits `appintent-enum-no-display`
- **Enum without assistant:** `AppEnum` used as parameter but no `@AssistantEnum` -- emits `appintent-enum-not-assistant`
- **Enum case coverage:** `AppEnum` with 3 cases but `caseDisplayRepresentations` has 2 entries -- emits `appintent-enum-case-no-display`
- **No shortcuts provider:** File has intents but no `AppShortcutsProvider` -- emits warning
- **Skip behavior:** File without `import AppIntents` -- returns `.skipped`
- **Multiple intents per file:** Two `AppIntent` structs, one complete, one missing description -- emits exactly one diagnostic
- **Extension conformance:** Intent declared in extension -- detected by AST pass
- **Cross-file conformance (index pass):** Intent struct in file A, `: AppIntent` conformance in file B -- detected by index pass when available
- **Orphan entity:** `AppEntity` defined but never used as a parameter type -- emits `appintent-orphan-entity`

**Reference Truth:** Apple's App Intents framework documentation and WWDC sessions (2022-2025). Specifically:
- WWDC22: "Dive into App Intents" -- foundational protocol requirements
- WWDC23: "Explore enhancements to App Intents" -- entity queries, `@AssistantIntent`
- WWDC24: "Bring your app to Siri" -- Apple Intelligence integration requirements
- Apple Developer Documentation: "Making your app's functionality available to Siri"

**Validation Trace:**
```swift
// Input:
struct OpenPortfolio: AppIntent {
    static var title: LocalizedStringResource = "Open Portfolio"
    // No IntentDescription
    // No @AssistantIntent
    @Parameter var portfolio: String  // No title:
    func perform() async throws -> some IntentResult { .result() }
}

// Expected diagnostics:
// - appintent-no-description (warning) at struct declaration line
// - appintent-no-assistant-schema (warning) at struct declaration line
// - appintent-param-no-title (warning) at @Parameter declaration line
```

```swift
// Input:
enum Priority: String, AppEnum {
    case low, medium, high
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"
    static var caseDisplayRepresentations: [Priority: DisplayRepresentation] = [
        .low: "Low",
        .high: "High",
        // .medium missing
    ]
}

// Expected diagnostics:
// - appintent-enum-case-no-display (warning) -- "medium" not in caseDisplayRepresentations
// - appintent-enum-not-assistant (warning) -- no @AssistantEnum annotation
```

## 11. Architecture Decision Review

**ADR Check:**
- [x] Reviewed existing checkers for architectural patterns (MCPReadinessAuditor is the closest analog; UnreachableCodeAuditor for IndexStoreDB pattern)
- [ ] Does this supersede an existing ADR? No
- [ ] Does this amend an existing ADR? No
- [x] New ADR required? Yes -- draft below

**New ADR Draft:**
- Title: IndexStoreInfra -- shared IndexStoreDB infrastructure for cross-file analysis
- Category: architecture
- Key decision: Extract `IndexStoreManager` from UnreachableCodeAuditor into a new `IndexStoreInfra` SPM module. All checkers that need cross-file type information depend on this module rather than reimplementing index store plumbing. The module provides store location, staleness checking, conformance queries, and a lightweight symbol graph. This is done as part of the AppIntentsAuditor work (the second consumer) rather than deferred, establishing the shared pattern before more checkers adopt it.

## 12. Adversarial Review

**Strongest case for a different approach:**
A reviewer might argue this should be a Swift Macro or compiler plugin rather than a quality-gate checker, since App Intents are a compile-time concern. A macro could emit `#warning` or `#error` at the declaration site, giving Xcode inline feedback rather than a separate CLI pass.

Why we're not doing that: Macros require attaching to declarations (`@ValidateIntent struct Foo`), which is invasive. The quality-gate approach is non-invasive, consistent with how we audit everything else, and catches cross-file concerns (like "intents exist but no ShortcutsProvider" or "entity defined but never used as a parameter") that a per-declaration macro cannot.

**Where this design is most likely wrong:**
The assumption that `import AppIntents` is a reliable signal for "this project uses App Intents." A project might import it transitively or conditionally. If this assumption breaks, we'd get false skips. Mitigation: the checker also accepts `enabled: true` in config to force the audit regardless of imports.

**What an experienced critic would say:**
"You're treating missing `@AssistantIntent` as a warning, but many existing apps have perfectly valid `AppIntent` conformances that predate Apple Intelligence. You'll flood them with warnings on first run." Valid concern. The response: this is the right default because Apple Intelligence is the direction the platform is heading. Projects that haven't adopted it yet need to see the gap clearly. The warnings are actionable (add the annotation) and the config supports `excludePaths` for legacy code that won't be updated.

## 13. Alternatives Considered

**Alternative 1: Extend HIGAuditor to cover App Intents**
- Advantage: No new module; HIG already audits Apple-platform conventions
- Disadvantage: HIGAuditor focuses on UI patterns (accessibility labels, minimum tap targets). App Intents are an API contract concern, not a HIG concern. Mixing them conflates two distinct categories
- Why rejected: Separation of concerns. Different skip conditions (HIGAuditor runs on UI code, this runs on intent code)

**Alternative 2: Swift compiler plugin / macro**
- Advantage: Inline Xcode feedback, no separate CLI step
- Disadvantage: Requires `@Validate` annotation on every intent (invasive), can't catch cross-file issues like missing `AppShortcutsProvider`, adds build-time dependency
- Why rejected: Quality-gate pattern is non-invasive and handles project-level concerns

**Alternative 3: Simple grep-based checker (no SwiftSyntax)**
- Advantage: Faster, simpler, no SwiftSyntax dependency
- Disadvantage: Can't distinguish `@Parameter(title: "Name") var name` from `@Parameter var name` reliably. String matching breaks on multi-line declarations, comments, and string literals
- Why rejected: The MCPReadinessAuditor already proved that AST-based analysis is worth the SwiftSyntax dependency for schema auditing

**Alternative 4: AST-only analysis (no IndexStoreDB)**
- Advantage: Simpler, no dependency on build artifacts, runs on Linux
- Disadvantage: Misses cross-file conformances, can't detect orphan entities, can't verify parameter type relationships
- Why rejected: The IndexStoreDB dependency already exists in the project. The two-pass architecture gives us cross-file accuracy when available and graceful degradation when not. The UnreachableCodeAuditor proved this pattern works

## 14. Future Directions

- **SiriKit migration detector** -- Could flag legacy `INIntent` subclasses that should migrate to `AppIntent`
- **Phrase quality scoring** -- Could analyze `AppShortcutsProvider` phrase strings for naturalness and collision avoidance
- **Parameter coverage** -- Could cross-reference `@Parameter` properties against `perform()` body to detect unused parameters (analogous to `mcp-unused-property`)
- **WidgetKit integration** -- Could check that `AppIntent` types used in widget configurations have appropriate `WidgetConfigurationIntent` conformance
- **Cross-checker correlation** -- Could correlate MCP tools with App Intents to detect functionality exposed via MCP but not via App Intents (or vice versa), flagging gaps in the AI integration surface
- **IndexStoreInfra adoption by other checkers** -- Once the shared infrastructure ships with this work, other checkers (MCPReadinessAuditor, RecursionAuditor, ComplexityAnalyzer, ConcurrencyAuditor, DocCoverageChecker, TestQualityAuditor) could adopt it incrementally for cross-file analysis
- **Dead protocol detection** -- New checker powered by IndexStoreInfra: find protocols with zero conformers
- **Unused import detection** -- New checker powered by IndexStoreInfra: find imports where no symbols from the imported module are referenced

## 15. Open Questions

*Resolved:*
- ~~Should the checker distinguish between `AssistantIntent` (Apple Intelligence) and plain `AppIntent` (Shortcuts only) in its severity levels?~~ **Resolved: Apple Intelligence is first-class. Missing `@AssistantIntent` is a warning, not a note. Visual distinction in output (separate "Apple Intelligence Readiness" category) helps developers understand the gap, but the severity treats it as expected behavior.**
- ~~Should we audit `AppEnum` completeness at the same depth as entities?~~ **Resolved: Yes. Full audit including `typeDisplayRepresentation`, `caseDisplayRepresentations` coverage, and `@AssistantEnum` annotation.**

*Remaining:*
- None. All open questions resolved.

## 16. Documentation Strategy

**Documentation Type:** Narrative Article Required + Blog Post

**Complexity Threshold Check:**
- Does it combine 3+ APIs? Yes -- AppIntent, AppEntity, AppEnum, AppShortcutsProvider, @AssistantIntent, @AssistantEnum, @AssistantEntity
- Does explanation require 50+ lines? Yes -- mapping Apple's framework concepts to checker rules needs context
- Does it need theory/background context? Yes -- developers need to understand why Apple Intelligence integration matters and what the checker is looking for

**Article Name:** `AppIntentsGuide.md` (in `.docc` catalog)
Contents:
- What App Intents are and why they matter for Apple Intelligence
- Overview of the two-pass analysis architecture
- Complete rule reference with examples and fix guidance for each diagnostic
- Configuration options and when to use them
- How this checker relates to MCP Readiness (same principle, different AI system)

**IndexStoreInfra Article:** `IndexStoreInfraGuide.md` (in `.docc` catalog)
Contents:
- What IndexStoreDB is and how Apple's compiler index works (index store location, symbol/occurrence model, relationship kinds)
- Why cross-file analysis matters for quality tooling -- what single-file SwiftSyntax parsing misses (split conformances, cross-module extensions, call graphs, orphan symbols)
- The StoreLocator, ConformanceQuery, and SymbolGraph APIs -- what each provides and when to use them
- Concrete examples: how AppIntentsAuditor uses ConformanceQuery to find split conformances, how UnreachableCodeAuditor uses SymbolGraph for dead code
- Upgrade roadmap: the 8 checkers that can adopt IndexStoreInfra and what each gains (with specific examples of currently-missed diagnostics that become possible)
- Graceful degradation: how checkers fall back when the index store is stale or missing
- How to build a new checker that leverages IndexStoreInfra (step-by-step pattern)

**Blog Post:** Separate deliverable (not in source tree)
Contents:
- Product announcement: "quality-gate now audits Apple Intelligence readiness"
- The thesis: if your app talks to an AI (Apple Intelligence, Siri, Claude via MCP), the metadata must be complete -- quality-gate enforces this
- How the two-pass architecture (SwiftSyntax + IndexStoreDB) enables cross-file analysis
- How easy it was to add a new checker to the existing quality-gate architecture (one SPM module, one protocol conformance, one line in the CLI registration)
- Comparison with MCP Readiness Auditor: same pattern, different AI surface
- IndexStoreInfra as shared infrastructure: what it unlocks for all existing checkers (dead protocol detection, unused import detection, cross-file mutual recursion, actor isolation verification)
