import Foundation
import QualityGateCore
import QualityGateTypes
import SwiftParser
import SwiftSyntax

/// Detects ethical context violations in Swift source code.
///
/// Scans for sensitive API usage without consent guards, unguarded analytics,
/// automated decisions without human review, and surveillance patterns.
///
/// ## Rules
///
/// - `context.missing-consent-guard` — Sensitive API without consent check
/// - `context.unguarded-analytics` — Analytics tracking without opt-out guard
/// - `context.automated-decision-without-review` — Automated user-affecting decision
/// - `context.surveillance-pattern` — Background tracking without disclosure
public struct ContextAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "context"

    /// Human-readable name for this checker.
    public let name = "Context Auditor"

    /// Creates a new ContextAuditor instance.
    public init() {}

    /// Run the context audit on the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []

        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            allDiagnostics = try await auditDirectory(
                at: sourcesPath,
                configuration: configuration
            )
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .warning

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    /// Audit a single source code string.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to audit.
    ///   - fileName: The file path (used for diagnostics and test-file detection).
    ///   - configuration: The project configuration.
    /// - Returns: A check result with any context violations found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let diagnostics = auditSourceCode(source, fileName: fileName)

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = diagnostics.isEmpty ? .passed : .warning

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Private Implementation

    private func auditDirectory(
        at path: String,
        configuration: Configuration
    ) async throws -> [Diagnostic] {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return []
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            if isTestFile(fullPath) { continue }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                diagnostics.append(contentsOf: auditSourceCode(source, fileName: fullPath))
            } catch {
                continue
            }
        }

        return diagnostics
    }

    private func auditSourceCode(_ source: String, fileName: String) -> [Diagnostic] {
        if isTestFile(fileName) {
            return []
        }

        let sourceFile = Parser.parse(source: source)
        let visitor = ContextVisitor(fileName: fileName, source: source)
        visitor.walk(sourceFile)

        return visitor.diagnostics
    }

    private func isTestFile(_ path: String) -> Bool {
        path.contains("Tests/") || path.contains("XCTests/")
    }
}
