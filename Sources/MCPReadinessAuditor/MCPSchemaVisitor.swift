import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Extracted Schema Types

/// Represents a single property extracted from an `MCPToolInputSchema`.
struct MCPExtractedProperty: Sendable {
    /// The JSON Schema type string (e.g. "string", "integer", "boolean", "array").
    let type: String
    /// The human-readable description, if present.
    let description: String?
    /// The line number where this property was defined.
    let line: Int
}

/// Represents a full tool schema extracted from an `MCPTool(...)` initializer.
struct MCPExtractedSchema: Sendable {
    /// The tool name from `name:` argument.
    let name: String
    /// The tool description from `description:` argument.
    let description: String
    /// Properties extracted from `inputSchema.properties`.
    let properties: [String: MCPExtractedProperty]
    /// Required property names from `inputSchema.required`.
    let required: Set<String>
    /// Line number of the tool declaration.
    let line: Int
}

/// Represents an argument access in an `execute()` method body.
struct MCPExtractedArgAccess: Sendable {
    /// The argument key string literal (e.g. "query").
    let key: String
    /// The getter method name (e.g. "getString", "getDoubleOptional").
    let getterName: String
    /// Whether this is a throwing (non-optional) getter.
    let isThrowing: Bool
    /// The line number of this access.
    let line: Int
}

// MARK: - Type Mapping

/// Maps getter method names to their expected JSON Schema type(s).
private let getterTypeMap: [String: Set<String>] = [
    "getString": ["string"],
    "getStringOptional": ["string"],
    "getInt": ["integer", "number"],
    "getIntOptional": ["integer", "number"],
    "getDouble": ["number"],
    "getDoubleOptional": ["number"],
    "getBool": ["boolean"],
    "getBoolOptional": ["boolean"],
    "getStringArray": ["array"],
    "getDoubleArray": ["array"],
]

/// Getter names that throw (non-optional variants).
private let throwingGetters: Set<String> = [
    "getString", "getInt", "getDouble", "getBool",
    "getStringArray", "getDoubleArray",
]

// MARK: - Visitor

/// SwiftSyntax visitor that detects MCP tool schema issues.
///
/// Walks a parsed Swift source file looking for struct declarations
/// that contain `MCPTool(...)` initializers. Extracts schema metadata
/// and cross-references it against `execute()` method bodies to detect
/// mismatches, missing descriptions, and unused properties.
///
/// ## Detected Rules
/// - `mcp-tool-no-description` — Tool has empty description
/// - `mcp-property-no-description` — Schema property has nil/empty description
/// - `mcp-schema-no-properties` — Execute accesses args but schema has no properties
/// - `mcp-arg-not-in-schema` — Argument key used in execute but not in schema
/// - `mcp-required-mismatch` — Throwing getter used but key not in required
/// - `mcp-type-mismatch` — Getter type doesn't match schema property type
/// - `mcp-unused-property` — Schema property never accessed in execute
/// - `mcp-description-too-short` — Description under minimum character length
final class MCPSchemaVisitor: SyntaxVisitor {
    /// File path used in emitted diagnostics.
    let filePath: String
    /// Source location converter for accurate line numbers.
    let converter: SourceLocationConverter
    /// Whether the file imports SwiftMCPServer.
    let hasMCPImport: Bool
    /// Configuration for minimum description length.
    let config: MCPReadinessConfig

    /// Collected diagnostics from the walk.
    private(set) var diagnostics: [Diagnostic] = []

    /// Creates a new MCP schema visitor.
    ///
    /// - Parameters:
    ///   - filePath: The file path for diagnostic messages.
    ///   - source: The full source text of the file.
    ///   - config: The MCP readiness configuration.
    ///   - tree: The parsed syntax tree.
    init(filePath: String, source: String, config: MCPReadinessConfig, tree: SourceFileSyntax) {
        self.filePath = filePath
        self.converter = SourceLocationConverter(fileName: filePath, tree: tree)
        self.hasMCPImport = source.contains("import SwiftMCPServer")
        self.config = config
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Struct Declarations

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard hasMCPImport else { return .skipChildren }

        // Look for a stored property named "tool" with MCPTool initializer
        var extractedSchema: MCPExtractedSchema?
        var extractedAccesses: [MCPExtractedArgAccess] = []

        for member in node.memberBlock.members {
            // Pass 1: Extract schema from `let tool = MCPTool(...)`
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                if let schema = extractSchema(from: varDecl) {
                    extractedSchema = schema
                }
            }

            // Pass 2: Extract argument accesses from `func execute(...)`
            if let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
                if funcDecl.name.text == "execute" {
                    extractedAccesses = extractArgAccesses(from: funcDecl)
                }
            }
        }

        // Cross-reference if we found a schema
        guard let schema = extractedSchema else { return .skipChildren }

        crossReference(schema: schema, accesses: extractedAccesses)

        return .skipChildren
    }

    // MARK: - Schema Extraction

    /// Extracts schema information from a variable declaration like `let tool = MCPTool(...)`.
    private func extractSchema(from varDecl: VariableDeclSyntax) -> MCPExtractedSchema? {
        for binding in varDecl.bindings {
            // Check the pattern is "tool"
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  identifier.identifier.text == "tool" else {
                continue
            }

            // Check the initializer is a function call to MCPTool
            guard let initClause = binding.initializer,
                  let callExpr = initClause.value.as(FunctionCallExprSyntax.self),
                  isMCPToolCall(callExpr) else {
                continue
            }

            return extractSchemaFromMCPTool(callExpr)
        }
        return nil
    }

    /// Checks whether a function call expression is `MCPTool(...)`.
    private func isMCPToolCall(_ call: FunctionCallExprSyntax) -> Bool {
        if let declRef = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text == "MCPTool"
        }
        if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text == "MCPTool"
        }
        return false
    }

    /// Extracts full schema information from an `MCPTool(name:description:inputSchema:)` call.
    private func extractSchemaFromMCPTool(_ call: FunctionCallExprSyntax) -> MCPExtractedSchema {
        var name = ""
        var description = ""
        var properties: [String: MCPExtractedProperty] = [:]
        var required: Set<String> = []
        let line = lineNumber(of: Syntax(call))

        for arg in call.arguments {
            switch arg.label?.text {
            case "name":
                name = extractStringLiteral(from: arg.expression) ?? ""
            case "description":
                description = extractStringLiteral(from: arg.expression) ?? ""
            case "inputSchema":
                if let schemaCall = arg.expression.as(FunctionCallExprSyntax.self) {
                    let extracted = extractInputSchema(from: schemaCall)
                    properties = extracted.properties
                    required = extracted.required
                }
            default:
                break
            }
        }

        return MCPExtractedSchema(
            name: name,
            description: description,
            properties: properties,
            required: required,
            line: line
        )
    }

    /// Extracts properties and required arrays from `MCPToolInputSchema(properties:required:)`.
    private func extractInputSchema(
        from call: FunctionCallExprSyntax
    ) -> (properties: [String: MCPExtractedProperty], required: Set<String>) {
        var properties: [String: MCPExtractedProperty] = [:]
        var required: Set<String> = []

        for arg in call.arguments {
            switch arg.label?.text {
            case "properties":
                properties = extractProperties(from: arg.expression)
            case "required":
                required = extractRequiredArray(from: arg.expression)
            default:
                break
            }
        }

        return (properties, required)
    }

    /// Extracts property definitions from a dictionary literal expression.
    private func extractProperties(from expr: ExprSyntax) -> [String: MCPExtractedProperty] {
        guard let dictExpr = expr.as(DictionaryExprSyntax.self),
              let elements = dictExpr.content.as(DictionaryElementListSyntax.self) else {
            return [:]
        }

        var result: [String: MCPExtractedProperty] = [:]

        for element in elements {
            guard let key = extractStringLiteral(from: element.key) else { continue }

            var type = ""
            var description: String?
            let propLine = lineNumber(of: Syntax(element))

            // Parse MCPSchemaProperty init call
            if let propCall = element.value.as(FunctionCallExprSyntax.self) {
                for propArg in propCall.arguments {
                    switch propArg.label?.text {
                    case "type":
                        type = extractStringLiteral(from: propArg.expression) ?? ""
                    case "description":
                        description = extractStringLiteral(from: propArg.expression)
                    default:
                        break
                    }
                }
            }

            result[key] = MCPExtractedProperty(
                type: type,
                description: description,
                line: propLine
            )
        }

        return result
    }

    /// Extracts string values from a required array literal.
    private func extractRequiredArray(from expr: ExprSyntax) -> Set<String> {
        guard let arrayExpr = expr.as(ArrayExprSyntax.self) else { return [] }
        var result: Set<String> = []
        for element in arrayExpr.elements {
            if let str = extractStringLiteral(from: element.expression) {
                result.insert(str)
            }
        }
        return result
    }

    // MARK: - Execute Body Analysis

    /// Extracts argument access calls from an `execute(arguments:)` method body.
    private func extractArgAccesses(from funcDecl: FunctionDeclSyntax) -> [MCPExtractedArgAccess] {
        guard let body = funcDecl.body else { return [] }
        var accesses: [MCPExtractedArgAccess] = []
        collectArgAccesses(from: Syntax(body), into: &accesses)
        return accesses
    }

    /// Recursively walks syntax nodes looking for getter calls like `args.getString("key")`.
    private func collectArgAccesses(from node: SyntaxProtocol, into accesses: inout [MCPExtractedArgAccess]) {
        if let call = Syntax(fromProtocol: node).as(FunctionCallExprSyntax.self),
           let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let methodName = memberAccess.declName.baseName.text

            if getterTypeMap.keys.contains(methodName) {
                // Extract the key string argument
                if let firstArg = call.arguments.first,
                   let key = extractStringLiteral(from: firstArg.expression) {
                    let access = MCPExtractedArgAccess(
                        key: key,
                        getterName: methodName,
                        isThrowing: throwingGetters.contains(methodName),
                        line: lineNumber(of: Syntax(call))
                    )
                    accesses.append(access)
                }
            }
        }

        for child in node.children(viewMode: .sourceAccurate) {
            collectArgAccesses(from: child, into: &accesses)
        }
    }

    // MARK: - Cross-Reference

    /// Performs cross-reference checks between extracted schema and argument accesses.
    private func crossReference(schema: MCPExtractedSchema, accesses: [MCPExtractedArgAccess]) {
        // Rule: mcp-tool-no-description
        if schema.description.isEmpty {
            emit(
                severity: .warning,
                message: "MCP tool '\(schema.name)' has empty description",
                line: schema.line,
                ruleId: "mcp-tool-no-description"
            )
        }

        // Rule: mcp-description-too-short (tool description)
        if !schema.description.isEmpty && schema.description.count < config.minDescriptionLength {
            emit(
                severity: .note,
                message: "MCP tool '\(schema.name)' description is \(schema.description.count) characters (minimum: \(config.minDescriptionLength))",
                line: schema.line,
                ruleId: "mcp-description-too-short"
            )
        }

        // Rule: mcp-property-no-description
        for (propName, prop) in schema.properties {
            if prop.description == nil || (prop.description?.isEmpty ?? true) {
                emit(
                    severity: .warning,
                    message: "MCP property '\(propName)' in tool '\(schema.name)' has no description",
                    line: prop.line,
                    ruleId: "mcp-property-no-description"
                )
            }
        }

        // Rule: mcp-description-too-short (property descriptions)
        for (propName, prop) in schema.properties {
            if let desc = prop.description, !desc.isEmpty, desc.count < config.minDescriptionLength {
                emit(
                    severity: .note,
                    message: "MCP property '\(propName)' description is \(desc.count) characters (minimum: \(config.minDescriptionLength))",
                    line: prop.line,
                    ruleId: "mcp-description-too-short"
                )
            }
        }

        // Rule: mcp-schema-no-properties
        if schema.properties.isEmpty && !accesses.isEmpty {
            emit(
                severity: .error,
                message: "MCP tool '\(schema.name)' accesses arguments but inputSchema has no properties",
                line: schema.line,
                ruleId: "mcp-schema-no-properties"
            )
        }

        let accessedKeys = Set(accesses.map(\.key))

        for access in accesses {
            // Rule: mcp-arg-not-in-schema
            guard let schemaProp = schema.properties[access.key] else {
                emit(
                    severity: .error,
                    message: "Argument '\(access.key)' accessed via \(access.getterName)() but not defined in inputSchema properties",
                    line: access.line,
                    ruleId: "mcp-arg-not-in-schema"
                )
                continue
            }

            // Rule: mcp-required-mismatch
            if access.isThrowing && !schema.required.contains(access.key) {
                emit(
                    severity: .warning,
                    message: "Argument '\(access.key)' uses throwing getter \(access.getterName)() but is not in inputSchema required array",
                    line: access.line,
                    ruleId: "mcp-required-mismatch"
                )
            }

            // Rule: mcp-type-mismatch
            if let expectedTypes = getterTypeMap[access.getterName] {
                if !expectedTypes.contains(schemaProp.type) {
                    emit(
                        severity: .error,
                        message: "Argument '\(access.key)' uses \(access.getterName)() but schema type is \"\(schemaProp.type)\" (expected: \(expectedTypes.sorted().joined(separator: " or ")))",
                        line: access.line,
                        ruleId: "mcp-type-mismatch"
                    )
                }
            }
        }

        // Rule: mcp-unused-property
        for (propName, prop) in schema.properties {
            if !accessedKeys.contains(propName) {
                emit(
                    severity: .warning,
                    message: "MCP property '\(propName)' defined in inputSchema but never accessed in execute()",
                    line: prop.line,
                    ruleId: "mcp-unused-property"
                )
            }
        }
    }

    // MARK: - Helpers

    /// Extracts the string value from a string literal expression.
    private func extractStringLiteral(from expr: ExprSyntax) -> String? {
        guard let stringLiteral = expr.as(StringLiteralExprSyntax.self) else { return nil }
        return stringLiteral.segments.compactMap { segment -> String? in
            segment.as(StringSegmentSyntax.self)?.content.text
        }.joined()
    }

    /// Computes the 1-based line number for a syntax node.
    private func lineNumber(of node: Syntax) -> Int {
        let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        return location.line
    }

    /// Emits a diagnostic with file path and optional line number.
    private func emit(severity: Diagnostic.Severity, message: String, line: Int, ruleId: String) {
        diagnostics.append(
            Diagnostic(
                severity: severity,
                message: message,
                filePath: filePath,
                lineNumber: line,
                ruleId: ruleId
            )
        )
    }
}
