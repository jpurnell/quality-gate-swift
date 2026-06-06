import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for `Unsafe*Pointer` values that escape the
/// `withUnsafe*` closure scope that owns their underlying memory.
///
/// See `PointerEscapeAuditorGuide.md` for the full rule list and the
/// canonical Accelerate FFT incident that motivated each rule.
public struct PointerEscapeAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker, used in diagnostics and configuration.
    public let id = "pointer-escape"
    /// Human-readable display name for this checker.
    public let name = "Pointer Escape Auditor"

    /// Function names whose pointer-accepting parameters are documented as
    /// safe to outlive the with-block (e.g. specific vDSP entry points).
    private let allowedEscapeFunctions: Set<String>

    /// Creates a pointer-escape auditor.
    /// - Parameter allowedEscapeFunctions: Function names whose pointer parameters are safe to outlive the with-block.
    public init(allowedEscapeFunctions: Set<String> = []) {
        self.allowedEscapeFunctions = allowedEscapeFunctions
    }

    /// Scans all Swift files under the project `Sources/` directory for pointer escapes.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []
        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let result = try await auditDirectory(at: sourcesPath)
            allDiagnostics.append(contentsOf: result.diagnostics)
            allOverrides.append(contentsOf: result.overrides)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed
        return CheckResult(checkerId: id, status: status, diagnostics: allDiagnostics, overrides: allOverrides, duration: duration)
    }

    /// Audits a single source string for pointer escapes.
    /// - Parameter source: The Swift source code to analyze.
    /// - Parameter fileName: The file path used in emitted diagnostics.
    /// - Parameter configuration: The quality-gate configuration.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let result = auditSourceCode(source, fileName: fileName)
        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = result.diagnostics.isEmpty ? .passed : .failed
        return CheckResult(checkerId: id, status: status, diagnostics: result.diagnostics, overrides: result.overrides, duration: duration)
    }

    // MARK: - Private

    private func auditDirectory(at path: String) async throws -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else { return ([], []) }
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSourceCode(source, fileName: fullPath)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                continue
            }
        }
        return (diagnostics, overrides)
    }

    private func auditSourceCode(_ source: String, fileName: String) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = PointerEscapeVisitor(
            fileName: fileName,
            converter: converter,
            allowedEscapeFunctions: allowedEscapeFunctions,
            sourceText: source
        )
        visitor.walk(tree)
        return (visitor.diagnostics, visitor.overrides)
    }
}
