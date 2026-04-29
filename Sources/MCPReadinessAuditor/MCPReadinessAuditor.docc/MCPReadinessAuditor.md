# ``MCPReadinessAuditor``

Validates MCP tool schema definitions are complete, consistent with their implementations, and agent-friendly.

## Overview

The MCP Readiness Auditor checks that MCP tool schemas (defined via `MCPToolInputSchema` and `MCPSchemaProperty`) match their `execute()` implementations. When an LLM calls an MCP tool, it relies entirely on the JSON Schema to construct the call — incomplete or inconsistent schemas cause hallucinated arguments, type mismatches, and silent failures.

This is an **opt-in** checker. It auto-detects MCP tool files by scanning for `import SwiftMCPServer` and is excluded from `--check all` by default. Enable it via `--check mcp-readiness` or config.

## Rules

### Schema Completeness

| Rule ID | Flags | Severity |
|---|---|---|
| `mcp-tool-no-description` | `MCPTool` has empty description | warning |
| `mcp-property-no-description` | `MCPSchemaProperty` has nil/empty description | warning |
| `mcp-schema-no-properties` | Tool accesses arguments but schema has no properties | error |

### Schema-Implementation Consistency

| Rule ID | Flags | Severity |
|---|---|---|
| `mcp-arg-not-in-schema` | `execute()` accesses key not in schema properties | error |
| `mcp-required-mismatch` | Throwing getter used but key not in `required` array | warning |
| `mcp-type-mismatch` | Getter type doesn't match schema property type | error |
| `mcp-unused-property` | Schema property never accessed in `execute()` | warning |

### Agent-Friendliness

| Rule ID | Flags | Severity |
|---|---|---|
| `mcp-description-too-short` | Description under `minDescriptionLength` characters | note |

## Configuration

```yaml
mcp-readiness:
  enabled: true
  minDescriptionLength: 10
  additionalPaths: []
  excludePaths: []
```

## Topics

### Essentials

- ``MCPReadinessAuditor``
- <doc:MCPReadinessAuditorGuide>
