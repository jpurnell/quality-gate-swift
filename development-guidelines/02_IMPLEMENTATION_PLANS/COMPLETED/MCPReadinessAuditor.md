# Design Proposal: MCP Readiness Auditor (Revised)

## 1. Problem

MCP tools in this ecosystem define their schemas inline via `MCPToolInputSchema` and `MCPSchemaProperty` structs (in `SwiftMCPServer`). When an LLM calls a tool, it constructs the call entirely from the JSON Schema surfaced by the MCP server — parameter names, types, descriptions, and enum values. If these schema definitions are incomplete or inconsistent with the `execute()` implementation, the failure mode is silent: the LLM hallucinates arguments, passes wrong types, or omits required fields, and the tool either crashes or returns garbage.

The previous version of this proposal targeted DocC comments. That was wrong — DocC is not the schema source. The `MCPToolInputSchema` is. The auditor must check the schema definitions themselves and their consistency with the `execute()` body.

### Concrete Failure Modes (from actual MCP server development)

| Failure | Root Cause | User Experience |
|---|---|---|
| LLM passes wrong argument name | Property exists in `execute()` via `getString("query")` but not in `inputSchema.properties` | `ToolError.missingRequiredArgument` or silent nil |
| LLM omits required field | Parameter used via `args.getString("key")` (throwing) but not in `inputSchema.required` | Crash: "Missing required argument: key" |
| LLM passes free-text where enum expected | Property has no `.enum` values but `execute()` switches on a fixed set | `.error(message: "Unknown value")` |
| LLM picks wrong tool | Tool `description` is vague or missing | Wrong tool called, confusing error |
| LLM can't self-correct | `execute()` throws generic error, no hint about valid values | Retry loop with same bad input |
| LLM passes wrong type | Schema says `"type": "string"` but `execute()` calls `getDouble()` | Type mismatch crash |

## 2. Objective

Add an `MCPReadinessAuditor` (`mcp-readiness`) as an **optional** checker that validates MCP tool schema definitions are complete, consistent with their implementations, and agent-friendly.

**Optional by default:** Not all quality-gate consumers build MCP servers. Excluded from `--check all` default; enabled via `--check mcp-readiness` or `mcp-readiness.enabled: true` in config.

## 3. Detection Strategy

### How to identify MCP tool files

**V1 — Convention-driven:** Scan `Sources/` for files importing `SwiftMCPServer`. Any file that `import SwiftMCPServer` contains MCP tool definitions. This is reliable because:
- All MCP servers in the ecosystem depend on `SwiftMCPServer`
- The `MCPToolHandler` protocol lives in that module
- No false positives: non-MCP code doesn't import it

**Fallback:** Config override for edge cases:
```yaml
mcp-readiness:
  enabled: true
  additionalPaths: []   # extra directories to scan
  excludePaths: []       # directories to skip
```

No module-list configuration required — auto-detection eliminates the stale-list problem.

## 4. Proposed Rules

### Schema Completeness (static analysis of `MCPTool` definitions)

| Rule ID | Flags | Severity |
|---|---|---|
| `mcp-tool-no-description` | `MCPTool` has empty or missing `description` | warning |
| `mcp-property-no-description` | `MCPSchemaProperty` has nil or empty `description` | warning |
| `mcp-schema-no-properties` | Tool with `execute()` that accesses arguments but `inputSchema.properties` is nil/empty | error |

### Schema-Implementation Consistency (cross-reference analysis)

| Rule ID | Flags | Severity |
|---|---|---|
| `mcp-arg-not-in-schema` | `execute()` calls `getString("key")` / `getInt("key")` etc. but `"key"` is not in `inputSchema.properties` | error |
| `mcp-required-mismatch` | `execute()` calls throwing getter `getString("key")` (not `getStringOptional`) but `"key"` is not in `inputSchema.required` | warning |
| `mcp-type-mismatch` | `execute()` calls `getDouble("key")` but schema property `"key"` has `type: "string"` | error |
| `mcp-unused-property` | Property defined in `inputSchema.properties` but never accessed in `execute()` | warning |

### Agent-Friendliness (heuristic quality checks)

| Rule ID | Flags | Severity |
|---|---|---|
| `mcp-description-too-short` | Tool or property description is under 10 characters | info |
| `mcp-missing-enum` | `execute()` uses a switch/if-else chain on a string argument but schema property has no `.enum` values | info |
| `mcp-error-not-actionable` | `execute()` throws `ToolError` without including valid values or format hints in the message | info |

## 5. Implementation

**Approach:** SwiftSyntax AST walking. Two-pass analysis per file:

### Pass 1: Schema Extraction
Walk struct declarations conforming to `MCPToolHandler`. For each:
1. Find the `tool` property's initializer
2. Extract `description` string literal
3. Parse `inputSchema` initializer to get `properties` dictionary (property names, types, descriptions, enum values) and `required` array
4. Store as structured data for cross-reference

### Pass 2: Execute Body Analysis
Walk the `execute(arguments:)` method body:
1. Find all `getString("key")`, `getInt("key")`, `getDouble("key")`, `getBool("key")`, `getStringOptional("key")`, etc. calls
2. Record each argument name and:
   - The getter used (typed: `getString` vs `getDouble` vs `getInt` etc.)
   - Whether throwing (`getString`) or optional (`getStringOptional`)
3. Cross-reference against Pass 1's schema data

### Cross-Reference Logic
```
For each argument used in execute():
  - Is it in schema.properties? (mcp-arg-not-in-schema)
  - Is the getter type consistent with schema property type? (mcp-type-mismatch)
  - If throwing getter, is it in schema.required? (mcp-required-mismatch)

For each property in schema:
  - Is it accessed in execute()? (mcp-unused-property)

For tool:
  - Is description non-empty? (mcp-tool-no-description)
  - For each property, is description non-empty? (mcp-property-no-description)
```

### Type Mapping Table

| Getter | Expected Schema Type |
|---|---|
| `getString` / `getStringOptional` | `"string"` |
| `getInt` / `getIntOptional` | `"integer"` or `"number"` |
| `getDouble` / `getDoubleOptional` | `"number"` |
| `getBool` / `getBoolOptional` | `"boolean"` |
| `getStringArray` | `"array"` with items type `"string"` |
| `getDoubleArray` | `"array"` with items type `"number"` |

### SwiftSyntax Feasibility

**What's easy:**
- Finding `MCPTool(name:description:inputSchema:)` initializers — string literal extraction
- Finding `MCPSchemaProperty(type:description:enum:)` — same pattern
- Finding `args.getString("key")` calls — member access + string literal argument
- Matching `required: ["key1", "key2"]` arrays — array literal extraction

**What's hard:**
- Schema properties built dynamically (e.g., from variables or computed properties) — accept that dynamic schemas can't be statically analyzed; skip with `info`-level "could not analyze" note
- Enum values computed at runtime (e.g., `enum: SomeType.allCases.map(\.rawValue)`) — flag as "unverifiable" but don't error
- Tools defined across multiple files (e.g., schema in one file, execute in another) — v1 requires both in the same file; v2 could do cross-file analysis

### Configuration

```yaml
mcp-readiness:
  enabled: false
  minDescriptionLength: 10
  additionalPaths: []
  excludePaths: []
```

## 6. Adversarial Review

### What could go wrong with this auditor?

**False positives from dynamic schemas:**
Some tools compute schemas dynamically:
```swift
MCPSchemaProperty(type: "string", description: "...", enum: GuidelinesLoader.allDocumentNames)
```
The auditor can extract `"string"` and `"..."` but not the runtime enum values. This is acceptable — the auditor flags the *static* parts it can verify and skips what it can't with a note.

**False negatives from indirect argument access:**
If `execute()` passes `arguments` to a helper function that does the actual extraction, the auditor won't see the `getString()` calls in `execute()` directly. Mitigation: follow one level of indirection (if `execute()` calls `self.someMethod(args)`, check that method too). Accept that deeply indirect patterns will be missed.

**Overlap with DocCoverageChecker:**
DocCoverageChecker ensures public APIs have `///` comments. MCPReadinessAuditor checks schema definitions, not comments. No overlap — they audit different artifacts.

**"MCP tools should have good schemas" is obvious — does this auditor earn its keep?**
Yes, because the cross-reference rules (`mcp-arg-not-in-schema`, `mcp-required-mismatch`, `mcp-type-mismatch`) catch bugs that are invisible until an LLM tries to use the tool. These are the kind of inconsistencies that survive manual review because the code "works" when called from Swift — the schema metadata is documentation-adjacent and rots.

**Should this be in quality-gate-swift or in SwiftMCPServer itself?**
Strong argument for SwiftMCPServer: the auditor is tightly coupled to `MCPToolHandler`, `MCPTool`, and `MCPSchemaProperty` types. If those types change, the auditor must change. Counter-argument: quality-gate-swift is the central static analysis tool; splitting checkers across repos creates maintenance burden. Recommendation: **implement in quality-gate-swift** but design the visitor to be robust against API evolution (match on function/type names, not internal structure).

**What about the official MCP SDK's `Tool` type vs. `MCPTool`?**
SwiftMCPServer wraps the SDK's `Tool` with `MCPTool` for ergonomics. The auditor should target `MCPTool` (the wrapper users write) not `Tool` (the SDK type they never touch directly). If `SwiftMCPServer` ever drops the wrapper, the auditor rules can adapt to target `Tool` directly.

## 7. Implementation Plan

| # | Step | Effort | Dependencies |
|---|---|---|---|
| 1 | Schema extraction: parse `MCPTool` and `MCPSchemaProperty` initializers from AST | Medium | SwiftSyntax |
| 2 | Execute body analysis: extract `getString()`/`getInt()` etc. calls with argument names | Medium | SwiftSyntax |
| 3 | Cross-reference engine: match schema ↔ implementation | Small | Steps 1-2 |
| 4 | Completeness rules: empty descriptions, missing properties | Small | Step 1 |
| 5 | Agent-friendliness rules: short descriptions, missing enums | Small | Steps 1-2 |
| 6 | Tests: unit tests with inline Swift source strings | Medium | Steps 1-5 |
| 7 | Configuration + registration in CLI | Small | Step 6 |
| 8 | DocC catalog (root + guide) | Small | Step 7 |
| 9 | Validate against DevGuidelinesMCP and GeoSEOMCP as real-world test | Medium | Step 8 |

## 8. Success Criteria

- Flags `MCPTool(name: "foo", description: "", ...)` — empty description
- Flags `args.getString("query")` when `"query"` not in `inputSchema.properties`
- Flags `getString("key")` (throwing) when `"key"` not in `required`
- Flags `getDouble("value")` when schema says `type: "string"`
- Passes well-formed tools like `ListSectionsTool` in DevGuidelinesMCP
- Returns `.skipped` when no `import SwiftMCPServer` files found
- DevGuidelinesMCP and GeoSEOMCP pass with zero false positives (validate before shipping)

## 9. Resolved Questions

1. ~~**Should this auditor live in quality-gate-swift or SwiftMCPServer?**~~ **RESOLVED: quality-gate-swift.** All checkers in one repo, one `quality-gate` command. The coupling to SwiftMCPServer's types is managed via an **integration test fixture**: quality-gate-swift's test suite includes a canonical SwiftMCPServer tool file (copied from real source) that the auditor parses. When SwiftMCPServer changes type signatures, the fixture goes stale, tests fail, and drift is caught before release.

2. ~~**Should `mcp-missing-enum` auto-detect switchable arguments?**~~ **RESOLVED: V1 — literal `switch`/`if-else` only.** Expand to `.contains()` checks in v2.

3. ~~**Should the auditor also check `MCPResourceProvider` and `MCPPromptProvider`?**~~ **RESOLVED: Tools only for v1.** Highest LLM-call volume. Expand to resources/prompts in v2.

4. ~~**Should the auditor validate that tool names follow a naming convention?**~~ **RESOLVED: Yes, `info`-level rule.** MCP spec doesn't mandate it but LLMs handle snake_case tool names more reliably.

5. ~~**V1 scope: same-file constraint?**~~ **RESOLVED: Yes.** V1 requires `MCPTool` schema and `execute()` body in the same file. Cross-file analysis deferred to v2.

### Drift Guard Mechanism

The auditor matches on SwiftMCPServer type/function names via SwiftSyntax (not `import`). The contract surface is:
- `MCPTool(name:description:inputSchema:)` initializer shape
- `MCPSchemaProperty(type:description:enum:)` initializer shape
- `MCPToolInputSchema(properties:required:)` initializer shape
- `getString()`, `getInt()`, `getDouble()`, `getBool()` and `*Optional` variants on arguments

**Guard:** A test fixture file (`Tests/Fixtures/mcp/CanonicalTool.swift`) contains a minimal but complete MCP tool copied from SwiftMCPServer. All auditor rules run against this fixture. When SwiftMCPServer's API changes:
1. The fixture is updated to match
2. Any auditor rules that break are fixed in the same PR
3. The fixture file header documents which SwiftMCPServer version it was copied from

---

**Date:** 2026-04-29 (revised 2026-05-05)
**Author:** Justin Purnell + Claude Opus 4.6
