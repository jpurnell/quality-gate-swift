import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import MCPReadinessAuditor
@testable import QualityGateCore

// MARK: - Test Helper

/// Parses a Swift source string and runs the MCPSchemaVisitor, returning diagnostics.
func diagnose(
    _ source: String,
    config: MCPReadinessConfig = .default
) -> [Diagnostic] {
    let tree = Parser.parse(source: source)
    let visitor = MCPSchemaVisitor(
        filePath: "test.swift",
        source: source,
        config: config,
        tree: tree
    )
    visitor.walk(tree)
    return visitor.diagnostics
}

// MARK: - Identity Tests

@Suite("MCPReadinessAuditor: Identity")
struct IdentityTests {
    @Test("Checker id is mcp-readiness")
    func checkerId() {
        let auditor = MCPReadinessAuditor()
        #expect(auditor.id == "mcp-readiness")
    }

    @Test("Checker name is MCP Readiness Auditor")
    func checkerName() {
        let auditor = MCPReadinessAuditor()
        #expect(auditor.name == "MCP Readiness Auditor")
    }
}

// MARK: - Well-Formed Tool Tests

@Suite("MCPReadinessAuditor: Well-formed tools")
struct WellFormedToolTests {
    @Test("Well-formed tool with all properties documented and used produces no diagnostics")
    func wellFormedToolNoDiagnostics() {
        let code = """
        import SwiftMCPServer

        struct SearchTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "search",
                description: "Search for items matching a query string in the database",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "query": MCPSchemaProperty(
                            type: "string",
                            description: "The search query to match against items"
                        ),
                    ],
                    required: ["query"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let query = try args.getString("query")
                return .success(text: query)
            }
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty, "Expected no diagnostics for well-formed tool, got: \(results)")
    }

    @Test("Tool with no arguments and empty schema produces no diagnostics")
    func toolNoArguments() {
        let code = """
        import SwiftMCPServer

        struct PingTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "ping",
                description: "Simple health check that returns pong response",
                inputSchema: MCPToolInputSchema(
                    properties: [:],
                    required: []
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                return .success(text: "pong")
            }
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty, "Expected no diagnostics for no-argument tool, got: \(results)")
    }
}

// MARK: - Schema Completeness Tests

@Suite("MCPReadinessAuditor: Schema Completeness")
struct SchemaCompletenessTests {
    @Test("Empty description on MCPTool triggers mcp-tool-no-description")
    func emptyToolDescription() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "",
                inputSchema: MCPToolInputSchema(
                    properties: [:],
                    required: []
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                return .success(text: "ok")
            }
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == "mcp-tool-no-description" })
    }

    @Test("MCPSchemaProperty with nil description triggers mcp-property-no-description")
    func nilPropertyDescription() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "query": MCPSchemaProperty(
                            type: "string"
                        ),
                    ],
                    required: ["query"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let query = try args.getString("query")
                return .success(text: query)
            }
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == "mcp-property-no-description" })
    }

    @Test("Tool accessing arguments but no properties in schema triggers mcp-schema-no-properties")
    func schemaNoProperties() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [:],
                    required: []
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let query = try args.getString("query")
                return .success(text: query)
            }
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == "mcp-schema-no-properties" })
    }
}

// MARK: - Schema-Implementation Consistency Tests

@Suite("MCPReadinessAuditor: Schema-Implementation Consistency")
struct SchemaConsistencyTests {
    @Test("execute() accesses key not in schema triggers mcp-arg-not-in-schema")
    func argNotInSchema() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "name": MCPSchemaProperty(
                            type: "string",
                            description: "The name of the item to search for"
                        ),
                    ],
                    required: ["name"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let name = try args.getString("name")
                let query = try args.getString("query")
                return .success(text: "\\(name) \\(query)")
            }
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == "mcp-arg-not-in-schema" })
    }

    @Test("Throwing getter but key not in required triggers mcp-required-mismatch")
    func requiredMismatch() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "key": MCPSchemaProperty(
                            type: "string",
                            description: "The key value for lookup in the store"
                        ),
                    ],
                    required: []
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let key = try args.getString("key")
                return .success(text: key)
            }
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == "mcp-required-mismatch" })
    }

    @Test("Type mismatch between getter and schema triggers mcp-type-mismatch")
    func typeMismatch() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "value": MCPSchemaProperty(
                            type: "string",
                            description: "The value to process in the calculation"
                        ),
                    ],
                    required: ["value"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let value = try args.getDouble("value")
                return .success(text: "\\(value)")
            }
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == "mcp-type-mismatch" })
    }

    @Test("Property in schema but never accessed in execute triggers mcp-unused-property")
    func unusedProperty() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "query": MCPSchemaProperty(
                            type: "string",
                            description: "The search query to look up records"
                        ),
                        "format": MCPSchemaProperty(
                            type: "string",
                            description: "The output format for returned results"
                        ),
                    ],
                    required: ["query"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let query = try args.getString("query")
                return .success(text: query)
            }
        }
        """
        let results = diagnose(code)
        #expect(results.contains { $0.ruleId == "mcp-unused-property" })
    }
}

// MARK: - Agent-Friendliness Tests

@Suite("MCPReadinessAuditor: Agent-Friendliness")
struct AgentFriendlinessTests {
    @Test("Description under minDescriptionLength triggers mcp-description-too-short")
    func descriptionTooShort() {
        let config = MCPReadinessConfig(
            enabled: true,
            minDescriptionLength: 20,
            additionalPaths: [],
            excludePaths: []
        )
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "Does stuff",
                inputSchema: MCPToolInputSchema(
                    properties: [:],
                    required: []
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                return .success(text: "ok")
            }
        }
        """
        let results = diagnose(code, config: config)
        #expect(results.contains { $0.ruleId == "mcp-description-too-short" })
    }

    @Test("Property description under minDescriptionLength triggers mcp-description-too-short")
    func propertyDescriptionTooShort() {
        let config = MCPReadinessConfig(
            enabled: true,
            minDescriptionLength: 20,
            additionalPaths: [],
            excludePaths: []
        )
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for users to run",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "query": MCPSchemaProperty(
                            type: "string",
                            description: "A query"
                        ),
                    ],
                    required: ["query"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let query = try args.getString("query")
                return .success(text: query)
            }
        }
        """
        let results = diagnose(code, config: config)
        #expect(results.contains { $0.ruleId == "mcp-description-too-short" })
    }
}

// MARK: - File Without MCP Import Tests

@Suite("MCPReadinessAuditor: Non-MCP files")
struct NonMCPFileTests {
    @Test("File without import SwiftMCPServer produces no diagnostics")
    func noMCPImport() {
        let code = """
        import Foundation

        struct RegularStruct {
            let name: String

            func doSomething() {
                print(name)
            }
        }
        """
        let results = diagnose(code)
        #expect(results.isEmpty, "Expected no diagnostics for non-MCP file, got: \(results)")
    }
}

// MARK: - Check Method Tests

@Suite("MCPReadinessAuditor: check() method")
struct CheckMethodTests {
    @Test("check() returns a result with correct checkerId")
    func checkReturnCorrectId() async throws {
        let auditor = MCPReadinessAuditor()
        let result = try await auditor.check(configuration: Configuration())
        #expect(result.checkerId == "mcp-readiness")
    }
}

// MARK: - Optional Getter Tests

@Suite("MCPReadinessAuditor: Optional getters")
struct OptionalGetterTests {
    @Test("Optional getter does not trigger mcp-required-mismatch")
    func optionalGetterNotRequired() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "format": MCPSchemaProperty(
                            type: "string",
                            description: "The output format for returned results"
                        ),
                    ],
                    required: []
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                let format = arguments?.getStringOptional("format")
                return .success(text: format ?? "default")
            }
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == "mcp-required-mismatch" })
    }
}

// MARK: - Multiple Getter Type Tests

@Suite("MCPReadinessAuditor: Type mappings")
struct TypeMappingTests {
    @Test("getInt with integer schema type does not trigger mcp-type-mismatch")
    func intTypeMatchesInteger() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "count": MCPSchemaProperty(
                            type: "integer",
                            description: "The number of items to return from query"
                        ),
                    ],
                    required: ["count"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let count = try args.getInt("count")
                return .success(text: "\\(count)")
            }
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == "mcp-type-mismatch" })
    }

    @Test("getInt with number schema type does not trigger mcp-type-mismatch")
    func intTypeMatchesNumber() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "count": MCPSchemaProperty(
                            type: "number",
                            description: "The number of items to return from query"
                        ),
                    ],
                    required: ["count"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let count = try args.getInt("count")
                return .success(text: "\\(count)")
            }
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == "mcp-type-mismatch" })
    }

    @Test("getBool with boolean schema type does not trigger mcp-type-mismatch")
    func boolTypeMatchesBoolean() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "verbose": MCPSchemaProperty(
                            type: "boolean",
                            description: "Whether to include detailed output info"
                        ),
                    ],
                    required: ["verbose"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let verbose = try args.getBool("verbose")
                return .success(text: "\\(verbose)")
            }
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == "mcp-type-mismatch" })
    }

    @Test("getStringArray with array schema type does not trigger mcp-type-mismatch")
    func stringArrayTypeMatchesArray() {
        let code = """
        import SwiftMCPServer

        struct FooTool: MCPToolHandler, Sendable {
            let tool = MCPTool(
                name: "foo",
                description: "A tool that does something useful for the user",
                inputSchema: MCPToolInputSchema(
                    properties: [
                        "tags": MCPSchemaProperty(
                            type: "array",
                            description: "List of tags to filter results by value"
                        ),
                    ],
                    required: ["tags"]
                )
            )

            func execute(arguments: [String: AnyCodable]?) async throws -> MCPToolCallResult {
                guard let args = arguments else { throw ToolError.missingArgument }
                let tags = try args.getStringArray("tags")
                return .success(text: tags.joined())
            }
        }
        """
        let results = diagnose(code)
        #expect(!results.contains { $0.ruleId == "mcp-type-mismatch" })
    }
}
