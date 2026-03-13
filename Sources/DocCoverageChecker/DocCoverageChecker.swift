import Foundation
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
/// let checker = DocCoverageChecker()
/// let result = try await checker.check(configuration: config)
/// ```
public struct DocCoverageChecker: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "doc-coverage"

    /// Human-readable name for this checker.
    public let name = "Documentation Coverage"

    /// Creates a new DocCoverageChecker instance.
    public init() {}

    /// Run the documentation coverage check on the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        // Find all Swift files in Sources/
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var totalPublicAPIs = 0
        var documentedAPIs = 0
        var allDiagnostics: [Diagnostic] = []

        if fileManager.fileExists(atPath: sourcesPath) {
            let (diagnostics, total, documented) = try await checkDirectoryWithStats(
                at: sourcesPath,
                configuration: configuration
            )
            allDiagnostics.append(contentsOf: diagnostics)
            totalPublicAPIs += total
            documentedAPIs += documented
        }

        let duration = ContinuousClock.now - startTime

        // Calculate coverage and determine status
        let coveragePercent = totalPublicAPIs > 0
            ? (documentedAPIs * 100) / totalPublicAPIs
            : 100

        let status: CheckResult.Status
        if let threshold = configuration.docCoverageThreshold {
            // Threshold mode: pass if coverage >= threshold
            status = coveragePercent >= threshold ? .passed : .failed
        } else {
            // Strict mode: fail if any undocumented APIs
            status = allDiagnostics.isEmpty ? .passed : .failed
        }

        // Add summary diagnostic
        var finalDiagnostics = allDiagnostics
        if totalPublicAPIs > 0 {
            let summaryMessage = "Documentation coverage: \(coveragePercent)% (\(documentedAPIs)/\(totalPublicAPIs) public APIs documented)"
            let summarySeverity: Diagnostic.Severity = status == .passed ? .note : .warning

            finalDiagnostics.insert(Diagnostic(
                severity: summarySeverity,
                message: summaryMessage,
                ruleId: "doc-coverage-summary"
            ), at: 0)
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
                // Skip files that can't be read
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
        let visitor = DocCoverageVisitor(fileName: fileName, source: source)
        visitor.walk(sourceFile)
        return (visitor.diagnostics, visitor.totalPublicAPIs, visitor.documentedAPIs)
    }
}

// MARK: - Syntax Visitor

private final class DocCoverageVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    var diagnostics: [Diagnostic] = []
    var totalPublicAPIs = 0
    var documentedAPIs = 0

    init(fileName: String, source: String) {
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
        let location = node.startLocation(converter: SourceLocationConverter(fileName: fileName, tree: node.root))

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Public \(apiType) '\(name)' is missing documentation",
            file: fileName,
            line: location.line,
            column: location.column,
            ruleId: "missing-doc",
            suggestedFix: "Add /// documentation comment above the declaration"
        ))
    }
}
