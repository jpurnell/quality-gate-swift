# Getting Started with MCPReadinessAuditor

@Metadata {
  @TechnologyRoot
}

## Overview

The MCP Readiness Auditor cross-references your MCP tool schemas against their `execute()` implementations, catching inconsistencies that cause LLM tool-call failures.

## What It Detects

### Missing Schema Properties (`mcp-arg-not-in-schema`)

When `execute()` accesses an argument not defined in the schema, LLMs can't know to pass it:

```swift
// ERROR: mcp-arg-not-in-schema — "format" not in inputSchema.properties
struct ExportTool: MCPToolHandler, Sendable {
    let tool = MCPTool(
        name: "export",
        description: "Export data",
        inputSchema: MCPToolInputSchema(
            properties: ["query": MCPSchemaProperty(type: "string", description: "Search query")],
            required: ["query"]
        )
    )

    func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
        let query = try args.getString("query")
        let format = try args.getString("format")  // Not in schema!
        // ...
    }
}
```

### Required Mismatch (`mcp-required-mismatch`)

When a throwing getter is used but the key isn't in `required`, the LLM may omit it:

```swift
// WARNING: mcp-required-mismatch — "limit" uses throwing getter but not in required
inputSchema: MCPToolInputSchema(
    properties: [
        "query": MCPSchemaProperty(type: "string", description: "Search query"),
        "limit": MCPSchemaProperty(type: "integer", description: "Max results"),
    ],
    required: ["query"]  // "limit" missing — but execute() throws on nil
)

func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
    let limit = try args.getInt("limit")  // Throws if missing!
}
```

Fix: add `"limit"` to `required` or use `getIntOptional("limit")`.

### Type Mismatch (`mcp-type-mismatch`)

When the getter type doesn't match the schema type:

```swift
// ERROR: mcp-type-mismatch — getDouble("count") but schema says "string"
properties: ["count": MCPSchemaProperty(type: "string", description: "Number of items")]

func execute(...) {
    let count = try args.getDouble("count")  // Schema says string!
}
```

### Empty Descriptions (`mcp-tool-no-description`, `mcp-property-no-description`)

LLMs choose tools and construct arguments based on descriptions. Missing ones cause wrong tool selection or garbage inputs:

```swift
// WARNING: mcp-tool-no-description
let tool = MCPTool(name: "do_thing", description: "", inputSchema: ...)

// WARNING: mcp-property-no-description
"query": MCPSchemaProperty(type: "string", description: nil)
```

## Opt-In Usage

This checker is excluded from `--check all` by default. Enable it:

```bash
# Run explicitly
quality-gate --check mcp-readiness

# Enable in config for all runs
# .quality-gate.yml:
# mcp-readiness:
#   enabled: true
```

## Auto-Detection

The auditor scans `Sources/` for files containing `import SwiftMCPServer`. No manual module list needed — if you import the MCP framework, your tools get checked.

## Integration

```bash
# Check MCP tools in your project
quality-gate --check mcp-readiness --strict

# Combine with other checks
quality-gate --check mcp-readiness --check doc-coverage --check safety
```
