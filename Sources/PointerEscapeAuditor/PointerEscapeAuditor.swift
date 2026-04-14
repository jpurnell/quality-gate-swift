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
    public let id = "pointer-escape"
    public let name = "Pointer Escape Auditor"

    /// Function names whose pointer-accepting parameters are documented as
    /// safe to outlive the with-block (e.g. specific vDSP entry points).
    private let allowedEscapeFunctions: Set<String>

    public init(allowedEscapeFunctions: Set<String> = []) {
        self.allowedEscapeFunctions = allowedEscapeFunctions
    }

    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            allDiagnostics.append(contentsOf: try await auditDirectory(at: sourcesPath))
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed
        return CheckResult(checkerId: id, status: status, diagnostics: allDiagnostics, duration: duration)
    }

    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let diagnostics = auditSourceCode(source, fileName: fileName)
        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = diagnostics.isEmpty ? .passed : .failed
        return CheckResult(checkerId: id, status: status, diagnostics: diagnostics, duration: duration)
    }

    // MARK: - Private

    private func auditDirectory(at path: String) async throws -> [Diagnostic] {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else { return [] }
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (path as NSString).appendingPathComponent(relativePath)
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
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = PointerEscapeVisitor(
            fileName: fileName,
            converter: converter,
            allowedEscapeFunctions: allowedEscapeFunctions,
            sourceText: source
        )
        visitor.walk(tree)
        return visitor.diagnostics
    }
}
