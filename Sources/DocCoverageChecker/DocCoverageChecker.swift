import Foundation
#if canImport(os)
import os
#endif
import IndexStoreInfra
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Checks for undocumented public APIs.
///
/// Uses SwiftSyntax to parse Swift source files and identify public
/// declarations that are missing documentation comments (`///`).
///
/// ## Usage
///
/// ```swift
/// import QualityGateCore
///
/// let config = Configuration()
/// let checker = DocCoverageChecker()
/// let result = try await checker.check(configuration: config)
/// ```
public struct DocCoverageChecker: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocCoverageChecker")

    /// Unique identifier for this checker.
    public let id = "doc-coverage"

    /// Human-readable name for this checker.
    public let name = "Documentation Coverage"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Undocumented public APIs, inherited documentation detection, usage-priority ranking"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.documentation

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.documentation

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Cross-module doc-coverage analysis (inherited docs) depends on the whole source tree,
    /// so the result is cacheable keyed by all Swift sources + manifests + config.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndIndex(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Creates a new DocCoverageChecker instance.
    public init() {}

    /// Sentinel error to short-circuit Pass 2 without propagating a real error.
    private enum SkipMarker: Error { case skipped }

    /// Run the documentation coverage check on the current directory.
    ///
    /// Runs Pass 1 (syntactic) unconditionally, then attempts Pass 2 (index-backed)
    /// if `configuration.docCoverage.useIndexStore` is true. Pass 2 degrades
    /// gracefully — a missing or stale index store never fails the quality gate.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Find all Swift files in Sources/
        let fileManager = FileManager.default
        let currentDir = configuration.resolvedProjectRoot.path
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var totalPublicAPIs = 0
        var documentedAPIs = 0
        var allDiagnostics: [Diagnostic] = []

        // Pass 1: syntactic analysis (always runs).
        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let (diagnostics, total, documented) = try await checkDirectoryWithStats(
                at: sourcesPath,
                configuration: configuration
            )
            allDiagnostics.append(contentsOf: diagnostics)
            totalPublicAPIs += total
            documentedAPIs += documented
        }

        // Pass 2: index-backed inherited-doc detection and usage-priority ranking (optional, graceful degradation).
        var inheritedDocCount = 0
        if configuration.docCoverage.useIndexStore && totalPublicAPIs > 0 {
            do {
                let (indexDiagnostics, inherited) = try await runIndexPass(
                    pass1Diagnostics: allDiagnostics,
                    totalPublicAPIs: totalPublicAPIs,
                    documentedAPIs: documentedAPIs,
                    configuration: configuration
                )
                allDiagnostics.append(contentsOf: indexDiagnostics)
                inheritedDocCount = inherited
            } catch SkipMarker.skipped {
                Self.logger.info("DocCoverage index pass skipped by marker")
            } catch {
                Self.logger.warning("DocCoverage index pass failed: \(error.localizedDescription, privacy: .public)")
                allDiagnostics.append(Diagnostic(
                    severity: .note,
                    message: "DocCoverage Pass 2 skipped: \(error.localizedDescription)",
                    ruleId: "doc-coverage.index-pass.skipped"
                ))
            }
        }

        let duration = ContinuousClock.now - startTime

        // Calculate coverage and determine status using effective coverage when Pass 2 ran.
        let effectiveDocumented = documentedAPIs + inheritedDocCount
        let coveragePercent = totalPublicAPIs > 0
            ? (effectiveDocumented * 100) / totalPublicAPIs
            : 100

        let status: CheckResult.Status
        if let threshold = configuration.docCoverageThreshold {
            // Threshold mode: pass if effective coverage >= threshold
            status = coveragePercent >= threshold ? .passed : .failed
        } else {
            // Strict mode: fail if any undocumented APIs (excluding inherited)
            let undocumentedCount = totalPublicAPIs - effectiveDocumented
            status = undocumentedCount <= 0 ? .passed : .failed
        }

        // Add summary diagnostic
        var finalDiagnostics = allDiagnostics
        if totalPublicAPIs > 0 {
            if inheritedDocCount > 0 {
                // Replace with adjusted summary showing both explicit and effective.
                let adjusted = DocCoverageIndexPass.adjustedSummary(
                    totalAPIs: totalPublicAPIs,
                    explicitlyDocumented: documentedAPIs,
                    inheritedCount: inheritedDocCount,
                    threshold: configuration.docCoverageThreshold
                )
                finalDiagnostics.insert(adjusted, at: 0)
            } else {
                let explicitPercent = totalPublicAPIs > 0
                    ? (documentedAPIs * 100) / totalPublicAPIs
                    : 100
                let summaryMessage = "Documentation coverage: \(explicitPercent)% (\(documentedAPIs)/\(totalPublicAPIs) public APIs documented)"
                let summarySeverity: Diagnostic.Severity = status == .passed ? .note : .warning

                finalDiagnostics.insert(Diagnostic(
                    severity: summarySeverity,
                    message: summaryMessage,
                    ruleId: "doc-coverage-summary"
                ), at: 0)
            }
        }

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: finalDiagnostics,
            duration: duration
        )
    }

    /// Check a single source code string for documentation coverage.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to check.
    ///   - fileName: The name of the file (for diagnostics).
    ///   - configuration: The project configuration.
    /// - Returns: A check result with any undocumented APIs found.
    public func checkSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let (diagnostics, _, _) = checkSourceCodeWithStats(
            source,
            fileName: fileName
        )

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = diagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    /// Check if a path should be excluded based on patterns.
    ///
    /// - Parameters:
    ///   - path: The file path to check.
    ///   - patterns: Glob patterns for exclusion.
    /// - Returns: true if the path should be excluded.
    public func shouldExclude(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pathMatches(path: path, pattern: pattern) {
                return true
            }
        }
        return false
    }

    // MARK: - Pass 2 (index-backed)

    /// Attempts to locate an index store and run inherited-doc detection and usage-priority ranking.
    private func runIndexPass(
        pass1Diagnostics: [Diagnostic],
        totalPublicAPIs: Int,
        documentedAPIs: Int,
        configuration: Configuration
    ) async throws -> (diagnostics: [Diagnostic], inheritedCount: Int) {
        let cwd = configuration.resolvedProjectRoot
        let kind = ProjectKind.detect(at: cwd)

        guard let located = try StoreLocator.locate(projectKind: kind) else {
            return ([DocCoverageIndexPass.unavailableNote()], 0)
        }

        guard let libPath = IndexStoreSession.findLibIndexStore() else {
            return ([DocCoverageIndexPass.unavailableNote()], 0)
        }

        let session = try await SharedIndexStore.session(storePath: located.url, libPath: libPath)

        // Step 1: Build undocumented APIs list from Pass 1 "missing-doc" diagnostics.
        let missingDocDiagnostics = pass1Diagnostics.filter { $0.ruleId == "missing-doc" }
        guard !missingDocDiagnostics.isEmpty else {
            // All APIs are already documented; nothing for Pass 2 to do.
            return ([], 0)
        }

        var undocumentedAPIs: [DocCoverageIndexPass.UndocumentedAPI] = []
        let messagePattern = /Public (\w+) '([^']+)' is missing documentation/

        // Collect distinct file paths that contain undocumented APIs for index lookup.
        var undocumentedFiles = Set<String>()
        for diag in missingDocDiagnostics {
            if let fp = diag.filePath {
                undocumentedFiles.insert(fp)
            }
        }

        // Query the index for all symbols defined in those files to enable USR resolution.
        let indexedSymbols = ConformanceQuery.symbolsInFiles(
            Array(undocumentedFiles),
            in: session
        )

        // Build a lookup from (filePath, symbolName) to USR for best-effort matching.
        var symbolUSRLookup: [String: String] = [:]
        for entry in indexedSymbols {
            let key = "\(entry.filePath):\(entry.symbol.name)"
            symbolUSRLookup[key] = entry.symbol.usr
        }

        for diag in missingDocDiagnostics {
            guard let match = diag.message.firstMatch(of: messagePattern) else { continue }
            let apiType = String(match.1)
            let apiName = String(match.2)
            let filePath = diag.filePath ?? ""
            let line = diag.lineNumber ?? 0

            // Attempt USR lookup by matching file path and symbol name.
            let lookupKey = "\(filePath):\(apiName)"
            let usr = symbolUSRLookup[lookupKey]

            undocumentedAPIs.append(DocCoverageIndexPass.UndocumentedAPI(
                name: apiName,
                apiType: apiType,
                filePath: filePath,
                line: line,
                usr: usr
            ))
        }

        // Step 2: Protocol inheritance detection.
        // Protocol-method USR resolution requires complex overrideOf/baseOf graph
        // traversal that IndexStoreDB does not directly expose. Return empty for now
        // so classifyInheritedDocs passes all APIs through as remaining.
        let protocolRequirementDocs: [String: Bool] = [:]

        // Step 3: Get reference counts for usage-priority ranking.
        var referenceCounts: [String: Int] = [:]
        for api in undocumentedAPIs {
            guard let usr = api.usr else { continue }
            let refs = ConformanceQuery.findReferences(toUSR: usr, in: session)

            // Optionally filter out test-target references.
            let filteredRefs: [ConformanceQuery.SymbolReference]
            if configuration.docCoverage.includeTestReferences {
                filteredRefs = refs
            } else {
                filteredRefs = refs.filter { ref in
                    !ref.filePath.contains("/Tests/")
                }
            }

            referenceCounts[api.name] = filteredRefs.count
        }

        // Step 4: Classify inherited docs and rank by usage.
        let (inheritedDiagnostics, remaining) = DocCoverageIndexPass.classifyInheritedDocs(
            undocumentedAPIs: undocumentedAPIs,
            protocolRequirementDocs: protocolRequirementDocs
        )
        let usagePriorityDiagnostics = DocCoverageIndexPass.rankByUsage(
            undocumentedAPIs: remaining,
            referenceCounts: referenceCounts
        )

        // Step 5: Return combined diagnostics and inherited count.
        let combinedDiagnostics = inheritedDiagnostics + usagePriorityDiagnostics
        return (combinedDiagnostics, inheritedDiagnostics.count)
    }

    // MARK: - Private Implementation

    private func checkDirectoryWithStats(
        at path: String,
        configuration: Configuration
    ) async throws -> (diagnostics: [Diagnostic], total: Int, documented: Int) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var totalAPIs = 0
        var documentedAPIs = 0

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return ([], 0, 0)
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            // Check exclude patterns
            if shouldExclude(path: fullPath, patterns: configuration.excludePatterns) {
                continue
            }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let (fileDiagnostics, total, documented) = checkSourceCodeWithStats(source, fileName: fullPath)
                diagnostics.append(contentsOf: fileDiagnostics)
                totalAPIs += total
                documentedAPIs += documented
            } catch {
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }

        return (diagnostics, totalAPIs, documentedAPIs)
    }

    private func pathMatches(path: String, pattern: String) -> Bool {
        // Simple glob matching for common patterns
        if pattern.contains("**") {
            let component = pattern.replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
            return path.contains(component)
        }
        return path.contains(pattern.replacingOccurrences(of: "*", with: ""))
    }

    private func checkSourceCodeWithStats(
        _ source: String,
        fileName: String
    ) -> (diagnostics: [Diagnostic], total: Int, documented: Int) {
        let sourceFile = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: sourceFile)
        let visitor = DocCoverageVisitor(fileName: fileName, source: source, converter: converter)
        visitor.walk(sourceFile)
        return (visitor.diagnostics, visitor.totalPublicAPIs, visitor.documentedAPIs)
    }
}

// MARK: - Syntax Visitor

private final class DocCoverageVisitor: SyntaxVisitor {
    /// Built once per file by the caller — see ConverterConstructionIsAClassDefect.md.
    let converter: SourceLocationConverter
    let fileName: String
    let source: String
    var diagnostics: [Diagnostic] = []
    var totalPublicAPIs = 0
    var documentedAPIs = 0

    init(fileName: String, source: String, converter: SourceLocationConverter) {
        self.converter = converter
        self.fileName = fileName
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Function Declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(modifiers: node.modifiers) {
            totalPublicAPIs += 1
            if hasDocComment(node) {
                documentedAPIs += 1
            } else {
                let name = node.name.text
                addDiagnostic(for: node, apiType: "function", name: name)
            }
        }
        return .visitChildren
    }

    // MARK: - Type Declarations

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(modifiers: node.modifiers) {
            totalPublicAPIs += 1
            if hasDocComment(node) {
                documentedAPIs += 1
            } else {
                let name = node.name.text
                addDiagnostic(for: node, apiType: "struct", name: name)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(modifiers: node.modifiers) {
            totalPublicAPIs += 1
            if hasDocComment(node) {
                documentedAPIs += 1
            } else {
                let name = node.name.text
                addDiagnostic(for: node, apiType: "class", name: name)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(modifiers: node.modifiers) {
            totalPublicAPIs += 1
            if hasDocComment(node) {
                documentedAPIs += 1
            } else {
                let name = node.name.text
                addDiagnostic(for: node, apiType: "enum", name: name)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(modifiers: node.modifiers) {
            totalPublicAPIs += 1
            if hasDocComment(node) {
                documentedAPIs += 1
            } else {
                let name = node.name.text
                addDiagnostic(for: node, apiType: "protocol", name: name)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(modifiers: node.modifiers) {
            totalPublicAPIs += 1
            if hasDocComment(node) {
                documentedAPIs += 1
            } else {
                let name = node.name.text
                addDiagnostic(for: node, apiType: "typealias", name: name)
            }
        }
        return .visitChildren
    }

    // MARK: - Variable Declarations

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(modifiers: node.modifiers) {
            totalPublicAPIs += 1
            if hasDocComment(node) {
                documentedAPIs += 1
            } else {
                // Extract the first binding name
                if let firstBinding = node.bindings.first,
                   let identifier = firstBinding.pattern.as(IdentifierPatternSyntax.self) {
                    let name = identifier.identifier.text
                    addDiagnostic(for: node, apiType: "property", name: name)
                }
            }
        }
        return .visitChildren
    }

    // MARK: - Initializer Declarations

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if isPublic(modifiers: node.modifiers) {
            totalPublicAPIs += 1
            if hasDocComment(node) {
                documentedAPIs += 1
            } else {
                addDiagnostic(for: node, apiType: "initializer", name: "init")
            }
        }
        return .visitChildren
    }

    // MARK: - Helpers

    private func isPublic(modifiers: DeclModifierListSyntax) -> Bool {
        for modifier in modifiers {
            if modifier.name.tokenKind == .keyword(.public) ||
               modifier.name.tokenKind == .keyword(.open) {
                return true
            }
        }
        return false
    }

    private func hasDocComment(_ node: some SyntaxProtocol) -> Bool {
        // Check the leading trivia for doc comments
        let leadingTrivia = node.leadingTrivia

        for piece in leadingTrivia {
            switch piece {
            case .docLineComment:
                return true
            case .docBlockComment:
                return true
            default:
                continue
            }
        }

        return false
    }

    private func addDiagnostic(for node: some SyntaxProtocol, apiType: String, name: String) {
        let location = node.startLocation(converter: converter)

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Public \(apiType) '\(name)' is missing documentation",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "missing-doc",
            suggestedFix: "Add /// documentation comment above the declaration"
        ))
    }
}
