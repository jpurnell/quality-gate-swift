# Design Proposal: IJS MCP Tools

## 1. Objective

**Objective:** Expose the Institutional Judgment System as MCP tools so AI assistants (Claude Code, etc.) can query the Pulse, record calibrations, check consistency, and list recent overrides without leaving their workflow.

**Master Plan Reference:** The IJS absorption proposal (section 14, "Future Directions") identifies "IJS as MCP tool" as the next step: "Expose Pulse queries and calibration recording as MCP tools for AI-assisted override workflows." This proposal fulfills that commitment.

## 2. Motivation

**Current situation:** Once the IJS is absorbed into quality-gate-swift (per the IJS absorption proposal), engineers interact with it in two ways: (1) the `consistency` checker runs during `quality-gate` and reports findings, and (2) engineers manually write `JudgmentCalibration` YAML files when overriding a finding. Neither path is accessible to AI assistants during code review or pair-programming sessions.

**Workaround:** When an AI assistant (Claude Code) encounters a quality gate override, it has no visibility into whether the override is consistent with institutional history. The engineer must leave the AI session, check the corpus manually, write a calibration file by hand, and return. Context is lost. Calibrations are incomplete or skipped entirely.

**Drawback:** The feedback loop that makes the IJS valuable --- override -> calibrate -> refine -> discover patterns --- breaks at the calibration step because it requires manual file authoring in a specific format. AI assistants, which are the primary override-assisting agents, cannot participate.

## 3. Proposed Architecture

### New Executable Target

A new `ijs-mcp-server` executable target that implements the MCP server protocol, exposing four tools. This follows the pattern of the existing `quality-gate` CLI --- a separate executable that depends on the IJS modules.

```
Sources/IJSMCPServer/
  IJSMCPServer.swift          -- @main entry point, MCP server setup
  QueryPulseTool.swift        -- ijs_query_pulse tool handler
  RecordCalibrationTool.swift -- ijs_record_calibration tool handler
  QueryConsistencyTool.swift  -- ijs_query_consistency tool handler
  ListOverridesTool.swift     -- ijs_list_overrides tool handler
```

### Module Dependency Graph

```
IJSMCPServer (executable)
  ├── SwiftMCPServer          (MCP protocol implementation)
  ├── IJSSensor               (value types: InstitutionalPulse, JudgmentCalibration, etc.)
  ├── IJSAggregator           (CorpusPath, TelemetryWriter)
  ├── IJSRefiner              (PulseRefiner)
  ├── IJSPolicyDiscovery      (ConsistencyScorer, PolicyDiscoveryAuditor)
  └── Foundation
```

### Modified Files

- `Package.swift` --- add `ijs-mcp-server` executable target with dependencies on SwiftMCPServer and IJS modules
- No changes to existing IJS modules --- the MCP server is a pure consumer

### New Dependencies

- [SwiftMCPServer](https://github.com/jpurnell/SwiftMCPServer) --- already used by other MCP servers in the ecosystem (DevGuidelinesMCP, GeoSEOMCP). Provides `MCPToolHandler`, `MCPTool`, `MCPSchemaProperty`, and the stdio transport.

## 4. API Surface

Four MCP tools, each implemented as a `MCPToolHandler` conformance:

```swift
// Tool 1: Query the Institutional Pulse
struct QueryPulseTool: MCPToolHandler {
    let tool = MCPTool(
        name: "ijs_query_pulse",
        description: "Read the latest InstitutionalPulse for a project, including trend analyses, violation clusters, statistical anomalies, and calibration summaries.",
        inputSchema: MCPToolInputSchema(properties: [...], required: ["project_id"])
    )
    func execute(arguments: ToolArguments) async throws -> [TextContent]
}

// Tool 2: Record a Judgment Calibration
struct RecordCalibrationTool: MCPToolHandler {
    let tool = MCPTool(
        name: "ijs_record_calibration",
        description: "Record a JudgmentCalibration when an engineer overrides a quality gate finding. Captures root cause analysis, risk tier, five-step stage, and optional red-team dissent.",
        inputSchema: MCPToolInputSchema(properties: [...], required: ["project_id", "rule_id", "override_rationale", "risk_tier", "root_cause"])
    )
    func execute(arguments: ToolArguments) async throws -> [TextContent]
}

// Tool 3: Query Consistency Score
struct QueryConsistencyTool: MCPToolHandler {
    let tool = MCPTool(
        name: "ijs_query_consistency",
        description: "Check the current project's consistency score and retrieve the specific findings driving it down.",
        inputSchema: MCPToolInputSchema(properties: [...], required: ["project_id"])
    )
    func execute(arguments: ToolArguments) async throws -> [TextContent]
}

// Tool 4: List Recent Overrides
struct ListOverridesTool: MCPToolHandler {
    let tool = MCPTool(
        name: "ijs_list_overrides",
        description: "Retrieve recent JudgmentCalibrations for a project to provide context during code review. Returns calibrations sorted by date, most recent first.",
        inputSchema: MCPToolInputSchema(properties: [...], required: ["project_id"])
    )
    func execute(arguments: ToolArguments) async throws -> [TextContent]
}
```

## 5. MCP Schema

This is the core of the proposal. Each tool's JSON Schema is defined in full.

### Tool 1: `ijs_query_pulse`

**Tool Description:** Read the latest InstitutionalPulse for a project, including trend analyses, violation clusters, statistical anomalies, and calibration summaries.

**REQUIRED STRUCTURE (JSON):**
```json
{
  "project_id": "quality-gate-swift",
  "include_trends": true,
  "include_clusters": true,
  "include_anomalies": true,
  "lookback_days": 30
}
```

**Parameter Types:**
- `project_id` (string, required): Project identifier matching the corpus subfolder name. Must be a valid directory name (alphanumeric, hyphens, underscores).
- `include_trends` (boolean, optional, default: true): Whether to include trend analyses (velocity, acceleration, direction) for each rule category.
- `include_clusters` (boolean, optional, default: true): Whether to include violation clusters (co-occurring rule violations across files).
- `include_anomalies` (boolean, optional, default: true): Whether to include statistical anomalies (z-score outliers from recent runs).
- `lookback_days` (integer, optional, default: 30): Number of days of history to include in the Pulse. Must be > 0 and <= 365.

**Response Shape:**
```json
{
  "project_id": "quality-gate-swift",
  "generated_at": "2026-05-13T14:30:00Z",
  "statistical_validity": "valid",
  "sample_count": 47,
  "calibration_summary": {
    "total_calibrations": 12,
    "by_risk_tier": {"1": 2, "2": 5, "3": 4, "4": 1},
    "by_root_cause": {"false_positive": 3, "acceptable_risk": 5, "deferred": 4}
  },
  "trends": [...],
  "clusters": [...],
  "anomalies": [...]
}
```

---

### Tool 2: `ijs_record_calibration`

**Tool Description:** Record a JudgmentCalibration when an engineer overrides a quality gate finding. Captures root cause analysis, risk tier, five-step stage, and optional red-team dissent. Writes to the cross-project corpus.

**REQUIRED STRUCTURE (JSON):**
```json
{
  "project_id": "quality-gate-swift",
  "rule_id": "safety.force-unwrap",
  "override_rationale": "Force unwrap is safe here because the value is validated by the guard on line 42.",
  "risk_tier": 2,
  "root_cause": "false_positive",
  "five_step_stage": "diagnose",
  "file_path": "Sources/SafetyAuditor/SafetyVisitor.swift",
  "line_number": 47,
  "red_team_dissent": "A future refactor could remove the guard, making this unsafe. Consider using optional binding instead.",
  "engineer": "jpurnell"
}
```

**Parameter Types:**
- `project_id` (string, required): Project identifier matching the corpus subfolder name.
- `rule_id` (string, required): The quality gate rule ID being overridden (e.g., `"safety.force-unwrap"`, `"concurrency.unchecked-sendable"`).
- `override_rationale` (string, required): Why the override is appropriate. Minimum 20 characters to discourage empty justifications.
- `risk_tier` (integer, required): Risk assessment from 1 (lowest) to 4 (highest). Enum values:
  - `1` --- Cosmetic / style concern, no functional impact
  - `2` --- Minor functional concern, low probability of defect
  - `3` --- Moderate concern, requires monitoring
  - `4` --- Significant concern, accepted under time pressure or with compensating controls
- `root_cause` (string, required): Why the finding was overridden. Enum values:
  - `"false_positive"` --- The auditor incorrectly flagged compliant code
  - `"acceptable_risk"` --- The risk is real but accepted given context
  - `"deferred"` --- The fix is planned but not immediate
  - `"design_constraint"` --- The flagged pattern is required by architecture or API contract
  - `"third_party"` --- The issue originates in code outside the project's control
- `five_step_stage` (string, optional, default: `"diagnose"`): Which Dalio five-step stage this override relates to. Enum values:
  - `"identify"` --- Identifying the problem
  - `"diagnose"` --- Diagnosing root causes
  - `"design"` --- Designing a solution
  - `"decide"` --- Deciding on an approach
  - `"execute"` --- Executing the solution
- `file_path` (string, optional): Path to the file containing the overridden finding, relative to project root.
- `line_number` (integer, optional): Line number of the overridden finding. Must be > 0.
- `red_team_dissent` (string, optional): Counterargument --- why this override might be wrong. Strongly encouraged for risk tier 3 and 4.
- `engineer` (string, optional): Engineer who approved the override. If omitted, defaults to the git user.

**Response Shape:**
```json
{
  "status": "recorded",
  "calibration_id": "cal-20260513-143000-safety-force-unwrap",
  "corpus_path": "quality-gate-swift/calibrations/2026-05-13/cal-20260513-143000-safety-force-unwrap.yml",
  "warnings": []
}
```

---

### Tool 3: `ijs_query_consistency`

**Tool Description:** Check the current project's consistency score and retrieve the specific findings driving it down. The score reflects how consistently the project applies its own override patterns.

**REQUIRED STRUCTURE (JSON):**
```json
{
  "project_id": "quality-gate-swift",
  "threshold": 0.75,
  "include_findings": true,
  "max_findings": 20
}
```

**Parameter Types:**
- `project_id` (string, required): Project identifier matching the corpus subfolder name.
- `threshold` (number, optional, default: 0.75): Minimum acceptable consistency score (0.0 to 1.0). Findings below this threshold are flagged.
- `include_findings` (boolean, optional, default: true): Whether to include the individual ConsistencyFindings that contribute to the score.
- `max_findings` (integer, optional, default: 20): Maximum number of findings to return. Must be > 0 and <= 100.

**Response Shape:**
```json
{
  "project_id": "quality-gate-swift",
  "consistency_score": 0.82,
  "statistical_validity": "valid",
  "sample_count": 47,
  "threshold": 0.75,
  "passed": true,
  "findings": [
    {
      "match_type": "conflicting_override",
      "rule_id": "safety.force-unwrap",
      "description": "Rule overridden with risk tier 2 in SafetyVisitor.swift but flagged as error in similar context in PointerValidator.swift",
      "severity": "warning",
      "related_calibrations": ["cal-20260501-...", "cal-20260503-..."]
    }
  ]
}
```

---

### Tool 4: `ijs_list_overrides`

**Tool Description:** Retrieve recent JudgmentCalibrations for a project to provide context during code review. Returns calibrations sorted by date, most recent first.

**REQUIRED STRUCTURE (JSON):**
```json
{
  "project_id": "quality-gate-swift",
  "limit": 10,
  "rule_id_filter": "safety.*",
  "risk_tier_min": 2,
  "since_date": "2026-04-01"
}
```

**Parameter Types:**
- `project_id` (string, required): Project identifier matching the corpus subfolder name.
- `limit` (integer, optional, default: 10): Maximum number of calibrations to return. Must be > 0 and <= 100.
- `rule_id_filter` (string, optional): Glob pattern to filter by rule ID (e.g., `"safety.*"`, `"concurrency.unchecked-sendable"`). If omitted, returns all rules.
- `risk_tier_min` (integer, optional): Minimum risk tier to include (1--4). If omitted, returns all tiers.
- `since_date` (string, optional): ISO 8601 date string (YYYY-MM-DD). Only return calibrations on or after this date. If omitted, no date filter.

**Response Shape:**
```json
{
  "project_id": "quality-gate-swift",
  "total_matching": 7,
  "returned": 7,
  "calibrations": [
    {
      "calibration_id": "cal-20260513-143000-safety-force-unwrap",
      "date": "2026-05-13T14:30:00Z",
      "rule_id": "safety.force-unwrap",
      "risk_tier": 2,
      "root_cause": "false_positive",
      "override_rationale": "Force unwrap is safe here because...",
      "file_path": "Sources/SafetyAuditor/SafetyVisitor.swift",
      "engineer": "jpurnell"
    }
  ]
}
```

## 6. Constraints & Compliance

**Concurrency:** All four tool handlers are structs conforming to `MCPToolHandler` (which requires `Sendable`). They hold no mutable state. The underlying IJS actors (`PulseRefiner`, `TelemetryWriter`, `PolicyDiscoveryAuditor`) are already Swift 6 actor-isolated. Tool handlers obtain actor instances per-request from a shared service layer, never storing them as properties.

**Determinism:** Read operations (`ijs_query_pulse`, `ijs_query_consistency`, `ijs_list_overrides`) are deterministic given the same corpus state. `ijs_record_calibration` is a write operation that generates a timestamp-based calibration ID --- determinism is not applicable.

**Safety:** No force unwraps. All string-to-enum conversions use failable initializers with descriptive error messages including the valid values. Corpus path validation rejects path traversal attempts (`..`). Write operations are append-only (new YAML files); no existing corpus data is modified or deleted.

**MCP Ready:** All tools follow the MCPReadinessAuditor's rules: descriptions > 10 characters, all parameters in `inputSchema.properties`, required fields match throwing getters, enum values listed exhaustively.

**Corpus Access:** The MCP server reads a `corpusPath` from its configuration (environment variable `IJS_CORPUS_PATH` or command-line argument). This is the same cross-project corpus used by the `consistency` checker. The MCP server requires read access for query tools and write access for `ijs_record_calibration`.

## 7. Source & API Compatibility

**Breaking changes:** None --- this is a new executable target with no existing callers. No modifications to existing IJS module APIs.

**Incremental adoption:** Yes --- the MCP server is an entirely separate target. Users who do not configure it in their MCP client see no change. Adding it requires a single entry in `.claude.json` or the MCP client's server configuration:

```json
{
  "mcpServers": {
    "ijs": {
      "command": "ijs-mcp-server",
      "args": ["--corpus-path", "/path/to/org-judgement-corpus"]
    }
  }
}
```

**Type-checking risk:** None --- no overloads of existing functions introduced.

## 8. Backend Abstraction

N/A --- the MCP server is I/O-bound (corpus file reads/writes) and performs lightweight JSON serialization. No compute-intensive operations.

## 9. Dependencies

**Internal Dependencies:**
- `IJSSensor` --- value types (`InstitutionalPulse`, `JudgmentCalibration`, `RiskTier`, `RootCauseAnalysis`, `FiveStepStage`, `ConsistencyFinding`, `ConsistencyReport`, etc.)
- `IJSAggregator` --- `CorpusPath`, `TelemetryWriter` (for `ijs_record_calibration`)
- `IJSRefiner` --- `PulseRefiner` (for `ijs_query_pulse`)
- `IJSPolicyDiscovery` --- `ConsistencyScorer`, `PolicyDiscoveryAuditor` (for `ijs_query_consistency`)

**External Dependencies:**
- [SwiftMCPServer](https://github.com/jpurnell/SwiftMCPServer) --- MCP protocol implementation. Already used by DevGuidelinesMCP and GeoSEOMCP. Provides stdio transport, tool registration, and argument parsing.
- [BusinessMath](https://github.com/jpurnell/BusinessMath) `from: "2.1.4"` --- transitively via `IJSRefiner`. Not imported directly by the MCP server target.

## 10. Test Strategy

**Test Categories:**

- **Golden path:** Known corpus with 5 calibrations and 3 daily snapshots -> `ijs_query_pulse` returns expected Pulse structure with correct statistics; `ijs_list_overrides` returns calibrations in descending date order; `ijs_query_consistency` returns expected score
- **Edge cases:** Empty corpus -> all query tools return valid but empty responses with `statistical_validity: "insufficient"`; single calibration -> `ijs_list_overrides` returns one result; `ijs_record_calibration` with minimum required fields -> writes valid YAML
- **Validation:** `ijs_record_calibration` with invalid `risk_tier` (0, 5) -> descriptive error with valid values listed; `override_rationale` under 20 characters -> error; `root_cause` not in enum -> error listing valid values; `since_date` not ISO 8601 -> error with format hint
- **Integration:** Round-trip test: record a calibration via `ijs_record_calibration`, then retrieve it via `ijs_list_overrides` and verify fields match
- **Schema consistency:** The MCPReadinessAuditor passes on all four tool files with zero warnings (validates schema completeness, argument-schema alignment, and type consistency)

**Reference Truth:** The Pulse statistics and consistency scores are validated against the existing IJS test suite (258 tests). MCP tool tests verify the serialization and argument parsing layers, not the statistical math.

**Validation Trace:**
- `ijs_query_pulse` with a 3-snapshot corpus where snapshot violation counts are [10, 8, 6] -> trend direction is `"improving"`, velocity is approximately -2.0 per period (validated against `TrendAnalysis.compute()` unit tests)
- `ijs_record_calibration` with all fields populated -> written YAML round-trips through `JudgmentCalibration` Codable decoder and all fields match input
- `ijs_query_consistency` with a corpus containing one conflicting override pair -> score < 1.0, findings array contains exactly one `"conflicting_override"` finding

## 11. Architecture Decision Review

**ADR Check:**
- [x] Reviewed `06_ARCHITECTURE_DECISIONS.md` for related decisions
- [ ] Does this supersede an existing ADR? No
- [ ] Does this amend an existing ADR? No
- [x] New ADR required? Yes -> draft entry below

**New ADR Draft:**
- Title: IJS exposed via dedicated MCP server executable, not embedded in quality-gate CLI
- Category: architecture
- Key decision: The IJS MCP tools are a separate executable target (`ijs-mcp-server`) rather than a subcommand of `quality-gate`, because MCP servers run as long-lived stdio processes while the CLI is a batch runner --- mixing both runtime models in one binary creates lifecycle complexity and confuses the argument parser.

## 12. Adversarial Review

**Strongest case for a different approach:**
Embed the IJS query tools as read-only endpoints in the `quality-gate` CLI itself (e.g., `quality-gate ijs pulse --project quality-gate-swift` with JSON output). AI assistants already invoke CLI tools via shell commands. A separate MCP server adds deployment complexity (configuring the server in `.claude.json`, ensuring the binary is on PATH, managing the corpus path). The CLI approach requires zero new infrastructure --- just parse the JSON output.

This alternative is genuinely compelling for the three read-only tools. It fails for `ijs_record_calibration` because calibration recording is an interactive, multi-field workflow that benefits from MCP's structured input (the AI fills in parameters, the tool validates, the AI can retry with corrections). A CLI invocation with 8 positional/flag arguments is fragile and error-prone.

**Where this design is most likely wrong:**
The assumption that AI assistants will call `ijs_record_calibration` during natural conversation flow. If engineers do not prompt the AI to record calibrations, the tool sits unused and the feedback loop remains broken --- the MCP server adds complexity without closing the gap. Mitigation: the `quality-gate` CLI could emit a hint when an override is detected: "Consider recording a calibration: ask your AI assistant to call `ijs_record_calibration`." This pushes adoption without mandating it.

**What an experienced critic would say:**
"You're building a second server binary for four tools --- three of which are trivial reads. This is over-engineered for a system that has zero users." We are proceeding because the MCP protocol requires a long-lived stdio process, which is architecturally incompatible with the batch CLI. The alternative (embedding MCP transport in the quality-gate CLI) would require the CLI to support both batch and streaming modes, which is more complexity than a clean separation.

## 13. Alternatives Considered

**Alternative 1: CLI subcommands instead of MCP server**
- Advantage: No new binary, no MCP server configuration, works with any AI assistant that can call shell commands
- Disadvantage: CLI output is unstructured text or requires JSON parsing; calibration recording via CLI flags is awkward (8+ parameters); no schema validation for AI assistants; no discoverability (AI must know the exact command syntax)
- Why rejected: MCP's structured input/output and tool discovery are the primary value proposition for AI-assisted workflows. The CLI approach solves none of the discoverability problems.

**Alternative 2: Embed MCP tools in the existing quality-gate CLI binary**
- Advantage: Single binary to build and distribute; shared configuration loading
- Disadvantage: The `quality-gate` CLI uses ArgumentParser for batch execution; MCP servers use stdio transport for long-lived streaming. Mixing both in one binary requires runtime mode detection (`quality-gate --mcp-mode` vs. `quality-gate --check all`), complicates signal handling, and confuses `--help` output
- Why rejected: Clean separation of concerns. The batch CLI and the MCP server have different lifecycles, different error handling models, and different deployment targets.

**Alternative 3: Add IJS tools to an existing MCP server (e.g., DevGuidelinesMCP)**
- Advantage: No new server binary; reuses existing MCP infrastructure
- Disadvantage: Couples IJS to an unrelated server; deployment of DevGuidelinesMCP would require IJS modules and BusinessMath even when IJS is not used; violates single-responsibility
- Why rejected: The IJS tools are specific to quality-gate-swift's domain. Bundling them in a guidelines server is a category error.

## 14. Future Directions

- **Pulse diff tool:** A fifth MCP tool (`ijs_diff_pulse`) that compares two Pulse snapshots and surfaces what changed --- useful for "what happened since last sprint" queries.
- **Calibration suggestions:** When `ijs_record_calibration` is called, the tool could suggest a `risk_tier` and `root_cause` based on historical patterns for similar rule IDs --- pre-filling fields from institutional memory.
- **Webhook integration:** Instead of polling via `ijs_query_pulse`, a push model where the MCP server notifies the AI assistant when the Pulse changes significantly (new anomaly, consistency score drop).
- **Multi-project dashboard tool:** A tool that queries the Pulse across all projects in the corpus and surfaces organization-wide patterns (which rules are most overridden, which projects have the lowest consistency).
- **MCP resource exposure:** Expose the Pulse as an MCP Resource (not just a tool), so AI assistants can subscribe to updates and include the Pulse in their context window automatically.

## 15. Open Questions

- **Corpus write concurrency:** If two AI assistants call `ijs_record_calibration` simultaneously for the same project, the corpus could have a write conflict (two YAML files in the same directory is fine, but if the corpus is git-backed, both would need to commit). Should the MCP server serialize writes via an actor, or rely on the filesystem's atomicity guarantees? The actor approach is simpler and correct for single-server deployment.
- **Authentication:** The MCP server has unrestricted write access to the corpus. Should `ijs_record_calibration` require an `engineer` field (mandatory, not optional) to create an audit trail? If so, where does the engineer identity come from --- MCP client metadata, environment variable, or explicit parameter?
- **Corpus bootstrapping:** If the MCP server is configured but the corpus directory does not exist for the requested project, should query tools return an error or auto-create the project subfolder? Auto-creation is friendlier but could mask misconfiguration.
- **Tool naming convention:** The proposed names use `ijs_` prefix with underscores (e.g., `ijs_query_pulse`). The MCPReadinessAuditor flags non-snake_case names at `info` level. Should the prefix be shorter (e.g., `pulse`, `calibrate`) for ergonomics, or is the namespace prefix worth the verbosity for discoverability?

## 16. Documentation Strategy

**Documentation Type:** Narrative Article Required

**Complexity Threshold Check:**
- Does it combine 3+ APIs? Yes (4 MCP tools, corpus configuration, MCP client setup, IJS concepts)
- Does explanation require 50+ lines? Yes
- Does it need theory/background context? Yes (MCP protocol basics, IJS five-step model, calibration workflow, consistency scoring)

**Article Name:** `IJSMCPToolsGuide.md`
(Placed in an IJSMCPServer.docc catalog, covering MCP client configuration, tool usage examples, calibration workflow walkthrough, and Pulse interpretation guide)

---

**Date:** 2026-05-13
**Author:** Justin Purnell + Claude Opus 4.6
