import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
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
    private static let logger = Logger(subsystem: "com.quality-gate", category: "MCPReadinessAuditor")
    /// Unique identifier for this checker.
    public let id = "mcp-readiness"
    /// Human-readable display name for this checker.
    public let name = "MCP Readiness Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "MCP tool schema vs. implementation cross-reference"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.specialty

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Creates a new MCP readiness auditor.
    public init() {}

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

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
        let root = configuration.resolvedProjectRoot
        let config = configuration.mcpReadiness

        // One walk of the whole root, where this used to walk `Sources/` plus each entry in
        // `mcpReadiness.additionalPaths`.
        //
        // `additionalPaths` is subsumed rather than ignored: every entry was resolved against
        // the project root, so each one names a subtree the root walk now covers anyway. The
        // key stays accepted so existing configurations keep loading, and it is now a no-op.
        // The old shape also double-counted — an `additionalPaths` entry inside `Sources/`
        // was walked twice, and `mcpFileCount` counted the same file each time.
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)

        var allDiagnostics: [Diagnostic] = []
        var mcpFileCount = 0

        let result = auditFiles(scan.files, config: config)
        allDiagnostics.append(contentsOf: result.diagnostics)
        mcpFileCount += result.mcpFileCount

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
    /// Audits an already-scoped list of Swift files; the walk decides what the run owns.
    private func auditFiles(
        _ paths: [String],
        config: MCPReadinessConfig
    ) -> (diagnostics: [Diagnostic], mcpFileCount: Int) {
        var diagnostics: [Diagnostic] = []
        var mcpFileCount = 0

        for fullPath in paths {
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
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
