# Design Proposal: Absorb Institutional Judgment System into quality-gate-swift

## 1. Objective

**Objective:** Absorb the standalone `org-judgement-system` package into quality-gate-swift so that every quality gate run participates in the institutional feedback loop — emitting telemetry, reading the Pulse, and scoring consistency.

**Master Plan Reference:** The IJS is the organizational learning layer described in the blog post "Building an Institutional Judgment System." It is fully implemented but isolated in its own repo with no integration into the quality gate it was built to serve.

## 2. Motivation

**Current situation:** The IJS exists as a separate Swift package (`org-judgement-system`) with a companion corpus repo (`org-judgement-corpus`). The quality gate runs without any awareness of institutional history — overrides, recurring violations, and policy drift are invisible.

**Workaround:** Running the IJS requires manually invoking `ijs-telemetry push` after each quality gate run, piping JSON output from one tool into another. No one does this.

**Drawback:** The four-layer feedback loop (Sensor → Aggregator → Refiner → PolicyDiscovery) never fires because the entry point isn't wired up. 27 source files and 258 tests sit unused. Override decisions evaporate.

## 3. Proposed Architecture

### Module Decomposition

The current monolithic `IJSCore` target splits into modules following quality-gate-swift's module-per-concern pattern. The critical constraint: several "upper" layer value types are needed by "lower" layers (e.g., `TelemetryWriter` reads `InstitutionalPulse`). Solution: pull all pure value types into the leaf module.

```
IJSSensor              — all value types across all four layers
  ↑
IJSAggregator          — CorpusPath, TelemetryWriter, TelemetryConfiguration, IJSError
  ↑
IJSRefiner             — PulseRefiner actor (only module needing BusinessMath)
  ↑
IJSPolicyDiscovery     — PolicyDiscoveryAuditor actor, ConsistencyScorer
  ↑
ConsistencyChecker     — QualityChecker conformance wrapper
```

### New Files

```
Sources/IJSSensor/
  RiskTier.swift
  FiveStepStage.swift
  RootCauseAnalysis.swift
  JudgmentCalibration.swift
  DecisionResponsibilityMatrix.swift
  CheckResultMetadata.swift
  StatisticalValidity.swift
  StatisticalAnomaly.swift
  TrendAnalysis.swift              (struct only, without compute())
  ViolationCluster.swift
  InstitutionalPulse.swift
  PulseStatistics.swift
  ConsistencyMatchType.swift
  ConsistencyFinding.swift
  ConsistencyReport.swift
  ConsistencyExemption.swift
  ScorerWeights.swift

Sources/IJSAggregator/
  CorpusPath.swift
  DailySnapshot.swift
  IJSError.swift
  TelemetryConfiguration.swift
  TelemetryWriter.swift

Sources/IJSRefiner/
  PulseRefiner.swift
  TrendAnalysis+Compute.swift      (extension with compute() static method)

Sources/IJSPolicyDiscovery/
  PolicyDiscoveryAuditor.swift
  ConsistencyScorer.swift

Sources/ConsistencyChecker/
  ConsistencyChecker.swift          (NEW — QualityChecker adapter)
```

### Modified Files

- `Package.swift` — add BusinessMath dependency, 5 new targets, 5 new test targets, update QualityGateCLI dependencies
- `Sources/QualityGateCore/Configuration.swift` — add `IJSConfig` struct and `ijs` property
- `Sources/QualityGateCLI/QualityGateCLI.swift` — register ConsistencyChecker, add post-run telemetry emission, add `telemetry-push` subcommand

## 4. API Surface

```swift
// ConsistencyChecker — the user-facing checker
public struct ConsistencyChecker: QualityChecker, Sendable {
    public let id = "consistency"
    public let name = "Institutional Consistency"
    public init()
    public func check(configuration: Configuration) async throws -> CheckResult
}

// IJSConfig — configuration section in .quality-gate.yml
public struct IJSConfig: Sendable, Codable, Equatable {
    public let projectID: String?
    public let corpusURL: String?
    public let localFallbackPath: String?
    public let consistencyThreshold: Double?
    public let defaultRiskTier: Int?
    public let scorerWeights: ScorerWeightsConfig?
    public static let `default`: IJSConfig
}

// Existing IJS types (migrated, public API unchanged):
// Sensor: JudgmentCalibration, RiskTier, RootCauseAnalysis, FiveStepStage,
//         DecisionResponsibilityMatrix, CheckResultMetadata
// Aggregator: TelemetryWriter, CorpusPath, DailySnapshot, TelemetryConfiguration
// Refiner: PulseRefiner, InstitutionalPulse, PulseStatistics, TrendAnalysis,
//          StatisticalAnomaly, StatisticalValidity, ViolationCluster
// PolicyDiscovery: PolicyDiscoveryAuditor, ConsistencyScorer, ConsistencyFinding,
//                  ConsistencyReport, ConsistencyExemption, ConsistencyMatchType
```

## 5. MCP Schema

The ConsistencyChecker is an internal quality gate checker, not an MCP tool. No MCP schema required.

If the IJS is later exposed as an MCP tool (e.g., for querying the Pulse or recording calibrations), schemas would be defined at that time.

## 6. Constraints & Compliance

**Concurrency:** All value types are already `Sendable`. Actors (`TelemetryWriter`, `PulseRefiner`, `PolicyDiscoveryAuditor`) use Swift 6 actor isolation. No changes needed.

**Determinism:** Statistical analysis in `PulseRefiner` is deterministic given the same corpus input. No randomness involved.

**Safety:** No force unwraps in existing IJS code. `ConsistencyChecker` returns `.passed` with an info note when IJS is not configured rather than failing.

**Corpus:** The corpus is a remote git repository (configured via `ijs.corpusURL` in `.quality-gate.yml`) with per-project subfolders. **This is nonstandard** — most quality gate configuration is self-contained within the project. The corpus is external because it accumulates institutional history across runs and is shared across projects. When the remote is unreachable or unconfigured, the system falls back to a local directory so the quality gate still runs. See `CrossProjectCorpus.md` for the full design.

## 7. Source & API Compatibility

**Breaking changes:** None — this adds new modules and a new opt-in checker. No existing APIs are modified.

**Incremental adoption:** Yes — ConsistencyChecker is included in default runs (opt-out). When the corpus is not configured or unreachable, it returns `.passed` with an info note rather than failing. Users who want to disable it add `consistency` to `excludePatterns` in `.quality-gate.yml`.

**Type-checking risk:** None — no overloads of existing functions introduced.

## 8. Backend Abstraction

N/A — the IJS is I/O-bound (file reads/writes) and performs lightweight statistics. No compute-intensive operations requiring GPU/Accelerate backends.

## 9. Dependencies

**Internal Dependencies:**
- `QualityGateCore` — for `QualityChecker` protocol, `CheckResult`, `Diagnostic`, `Configuration`
- `Yams` (already present) — for `TelemetryConfiguration` YAML parsing

**External Dependencies:**
- [BusinessMath](https://github.com/jpurnell/BusinessMath) `from: "2.1.4"` — statistical functions (`confidenceInterval`, `mean`, `stdDev`, `standardize`) used by `TrendAnalysis.compute()`. Only `IJSRefiner` depends on it; all other modules are free of it.

## 10. Test Strategy

**Migrated tests (28 files, ~258 tests):** All existing IJS tests migrate with updated imports. They use Swift Testing and cover every type across all four layers.

**Test Categories:**
- **Golden path:** Known corpus data → expected Pulse statistics, expected consistency scores
- **Edge cases:** Empty corpus, single entry, missing Pulse, unconfigured IJS
- **Determinism:** Same corpus → identical Pulse and consistency scores
- **Integration:** ConsistencyChecker produces valid CheckResult, maps findings to Diagnostics

**New integration tests:**
- `ConsistencyCheckerTests` — QualityChecker conformance, missing config handling, finding-to-diagnostic mapping
- `ConfigurationIJSTests` — `ijs:` section round-trips through Configuration Codable

**Reference Truth:** The statistical functions (z-scores, confidence intervals, trend analysis) are validated against BusinessMath's own test suite. IJS tests verify the orchestration, not the math.

**Validation Trace:**
- ConsistencyScorer with a known set of findings and validity-aware weights → expected score (existing tests cover this)
- StatisticalValidity classification: n < 3 → `.insufficient`, 3–29 → `.preliminary`, 30+ → `.valid` (existing tests)

## 11. Architecture Decision Review

**ADR Check:**
- [x] Reviewed `06_ARCHITECTURE_DECISIONS.md` for related decisions
- [ ] Does this supersede an existing ADR? No
- [ ] Does this amend an existing ADR? No
- [x] New ADR required? Yes → draft entry below

**New ADR Draft:**
- Title: Absorb IJS as internal modules rather than external dependency
- Category: architecture
- Key decision: IJS types are absorbed into quality-gate-swift as first-class modules rather than consumed as an SPM dependency, because the IJS is purpose-built for this tool and a circular dependency concern (quality-gate depends on IJS, IJS is about quality-gate) would create versioning friction.

## 12. Adversarial Review

**Strongest case for a different approach:**
Keep the IJS as a separate package and add it as an SPM dependency. This preserves the clean separation and lets the IJS evolve independently (e.g., for use with other linters or CI tools beyond quality-gate-swift). Absorption couples the IJS lifecycle to quality-gate-swift releases.

**Where this design is most likely wrong:**
The assumption that all value types can live in IJSSensor without circular dependencies. If any value type gains a method that depends on an upper-layer actor (e.g., a convenience method on `InstitutionalPulse` that calls `PulseRefiner`), the module graph breaks and types must be reshuffled.

**What an experienced critic would say:**
"You're pulling 27 files into a package that already has 51 targets — at what point does the Package.swift become unmaintainable?" We're proceeding because the module-per-concern pattern is already established and the IJS adds 5 targets (not 27), which is proportionate to other recent additions.

## 13. Alternatives Considered

**Alternative 1: SPM dependency (keep as separate package)**
- Advantage: Clean separation, independent versioning, reusable by other tools
- Disadvantage: Circular concern (IJS exists to serve quality-gate), two repos to coordinate, CI must resolve the dependency
- Why rejected: The IJS tracks quality-gate exceptions specifically. Keeping it separate created the integration gap that left it unused for weeks.

**Alternative 2: Monolithic IJSCore target (don't decompose)**
- Advantage: Simpler migration — copy one target instead of five
- Disadvantage: Violates quality-gate-swift's module-per-concern architecture, pulls BusinessMath into every consumer
- Why rejected: Consistency with existing patterns is worth the upfront decomposition cost.

**Alternative 3: Embed IJS logic directly into existing checkers (no separate modules)**
- Advantage: No new modules at all — telemetry is emitted from the CLI, consistency scoring is a post-processing step
- Disadvantage: Loses the clean four-layer architecture, scatters IJS logic across the codebase, makes the IJS untenable
- Why rejected: The layered architecture (Sensor → Aggregator → Refiner → PolicyDiscovery) is the IJS's core design strength.

## 14. Future Directions

- **IJS as MCP tool:** Expose Pulse queries and calibration recording as MCP tools for AI-assisted override workflows. See proposal: `IJSMCPTools.md`.
- **Cross-project corpus:** A single git-backed corpus tracking consistency across multiple repos, with per-project subfolders and organization-wide Pulse aggregation. See proposal: `CrossProjectCorpus.md`. Designed for parallel implementation with this proposal.
- **CI-native telemetry push:** GitHub Actions workflow step that automatically pushes telemetry after each quality gate run — the primary ingestion path, lower friction than local. See proposal: `CINativeTelemetryPush.md`. Designed for parallel implementation with this proposal.
- **Personal Judgment System integration:** The PJS (separate proposal) shares the five-step model and calibration types — could share IJSSensor types.

## 15. Open Questions (Resolved)

- **Corpus in CI:** ~~Should we support a remote corpus in v1?~~ **Resolved: Yes.** The corpus is a remote git repo (one repo, per-project subfolders). CI-native telemetry push is the primary ingestion path. See `CrossProjectCorpus.md` and `CINativeTelemetryPush.md`.
- **Opt-in vs opt-out:** ~~Should ConsistencyChecker be opt-in or opt-out?~~ **Resolved: Opt-out.** ConsistencyChecker is included in default runs. When the corpus is not configured or the git repo is unreachable, the checker returns `.passed` with an info note — graceful degradation, not failure.
- **TelemetryConfiguration migration:** ~~Manual Yams parsing vs Configuration Codable pipeline?~~ **Resolved: Use the existing pipeline.** quality-gate-swift already uses Yams via Configuration's Codable conformance. TelemetryConfiguration should plug into the same `ijs:` section rather than maintaining a parallel parser.

## 16. Documentation Strategy

**Documentation Type:** Narrative Article Required

**Complexity Threshold Check:**
- Does it combine 3+ APIs? Yes (5 modules, checker registration, CLI integration, configuration)
- Does explanation require 50+ lines? Yes
- Does it need theory/background context? Yes (Dalio's five-step model, CLT-based validity, institutional learning concepts)

**Article Name:** `InstitutionalJudgmentGuide.md`
(Placed in a ConsistencyChecker.docc catalog, following the existing per-module DocC pattern)
