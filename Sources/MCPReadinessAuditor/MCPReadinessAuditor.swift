import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source files for MCP tool schema issues and inconsistencies.
///
/// Detects files that `import SwiftMCPServer`, then cross-references
/// `MCPTool` schema definitions against `execute()` implementations to
/// catch schema-implementation drift, missing descriptions, type mismatches,
/// and unused properties.
///
/// ## Detected Rules
///
/// ### Schema Completeness
/// - `mcp-tool-no-description` — Tool has empty or missing description
/// - `mcp-property-no-description` — Schema property has nil or empty description
/// - `mcp-schema-no-properties` — Execute accesses args but schema has no properties
///
/// ### Schema-Implementation Consistency
/// - `mcp-arg-not-in-schema` — Argument key used in execute not in schema
/// - `mcp-required-mismatch` — Throwing getter used but key not in required
/// - `mcp-type-mismatch` — Getter type doesn't match schema property type
/// - `mcp-unused-property` — Schema property never accessed in execute
///
/// ### Agent-Friendliness
/// - `mcp-description-too-short` — Description under minimum character length
public struct MCPReadinessAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "mcp-readiness"
    /// Human-readable display name for this checker.
    public let name = "MCP Readiness Auditor"

    /// Creates a new MCP readiness auditor.
    public init() {}

    /// Audits Swift source files for MCP tool schema issues.
    ///
    /// Walks `Sources/` (and any `additionalPaths` from configuration) looking
    /// for files that `import SwiftMCPServer`. Only files with that import are
    /// parsed with SwiftSyntax for schema analysis.
    ///
    /// - Parameter configuration: Project-specific configuration.
    /// - Returns: The check result with status and diagnostics.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let config = configuration.mcpReadiness

        // Collect directories to scan
        var scanPaths: [String] = []
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")
        if fileManager.fileExists(atPath: sourcesPath) {
            scanPaths.append(sourcesPath)
        }
        for additional in config.additionalPaths {
            let fullPath = (currentDir as NSString).appendingPathComponent(additional)
            if fileManager.fileExists(atPath: fullPath) {
                scanPaths.append(fullPath)
            }
        }

        var allDiagnostics: [Diagnostic] = []
        var mcpFileCount = 0

        for scanPath in scanPaths {
            let result = auditDirectory(
                at: scanPath,
                config: config
            )
            allDiagnostics.append(contentsOf: result.diagnostics)
            mcpFileCount += result.mcpFileCount
        }

        let duration = ContinuousClock.now - startTime

        // If no MCP files found, skip
        guard mcpFileCount > 0 else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [],
                duration: duration
            )
        }

        let status: CheckResult.Status
        if allDiagnostics.contains(where: { $0.severity == .error }) {
            status = .failed
        } else if allDiagnostics.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .passed
        }

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    // MARK: - Private

    /// Scans a directory tree for Swift files containing MCP tool definitions.
    private func auditDirectory(
        at path: String,
        config: MCPReadinessConfig
    ) -> (diagnostics: [Diagnostic], mcpFileCount: Int) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var mcpFileCount = 0

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return ([], 0)
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            // Skip excluded paths
            let isExcluded = config.excludePaths.contains { excludePattern in
                fullPath.contains(excludePattern)
            }
            guard !isExcluded else { continue }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)

                // Quick text scan: only parse files that import SwiftMCPServer
                guard source.contains("import SwiftMCPServer") else { continue }

                mcpFileCount += 1
                let fileDiags = auditSourceCode(source, fileName: fullPath, config: config)
                diagnostics.append(contentsOf: fileDiags)
            } catch {
                continue
            }
        }

        return (diagnostics, mcpFileCount)
    }

    /// Parses a single source file and runs the MCP schema visitor.
    private func auditSourceCode(
        _ source: String,
        fileName: String,
        config: MCPReadinessConfig
    ) -> [Diagnostic] {
        let tree = Parser.parse(source: source)
        let visitor = MCPSchemaVisitor(
            filePath: fileName,
            source: source,
            config: config,
            tree: tree
        )
        visitor.walk(tree)
        return visitor.diagnostics
    }
}
