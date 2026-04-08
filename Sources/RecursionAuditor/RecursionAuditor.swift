import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source files for infinite-recursion bugs that compile cleanly.
///
/// Detected patterns:
/// - Convenience initializers that forward to `self.init(...)` with structurally
///   identical arguments (rule: `recursion.convenience-init-self`)
/// - Computed properties whose getter references the same property
///   (rule: `recursion.computed-property-self`)
/// - Subscripts whose getter references the same subscript with the same key
///   (rule: `recursion.subscript-self`)
/// - Functions whose every return path calls themselves with structurally
///   unchanged arguments and no guard-driven base case
///   (rule: `recursion.unconditional-self-call`, warning tier)
/// - Intra-file mutual recursion cycles with no base case in any participant
///   (rule: `recursion.mutual-cycle`, warning tier)
///
/// ## Usage
///
/// ```swift
/// let auditor = RecursionAuditor()
/// let result = try await auditor.auditSource(code, fileName: "F.swift", configuration: .init())
/// ```
public struct RecursionAuditor: QualityChecker, Sendable {
    public let id = "recursion"
    public let name = "Recursion Auditor"

    public init() {}

    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        if fileManager.fileExists(atPath: sourcesPath) {
            allDiagnostics.append(contentsOf: try await auditDirectory(at: sourcesPath, configuration: configuration))
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed
        return CheckResult(checkerId: id, status: status, diagnostics: allDiagnostics, duration: duration)
    }

    /// Audit a single source code string.
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

    /// Audit a multi-file project for cross-file mutual recursion.
    ///
    /// Builds a project-wide call graph keyed by qualified name, runs cycle
    /// detection, and emits one `recursion.mutual-cycle` diagnostic per
    /// participant in any cycle whose nodes lack a base case.
    public func auditProject(
        sources: [(fileName: String, source: String)],
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        var diagnostics: [Diagnostic] = []
        for entry in sources {
            diagnostics.append(contentsOf: auditSourceCode(entry.source, fileName: entry.fileName))
        }
        // RED stub: cross-file cycle detection arrives in GREEN.
        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = diagnostics.isEmpty ? .passed : .failed
        return CheckResult(checkerId: id, status: status, diagnostics: diagnostics, duration: duration)
    }

    // MARK: - Private

    private func auditDirectory(at path: String, configuration: Configuration) async throws -> [Diagnostic] {
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
        // RED stub: real implementation arrives in GREEN.
        return []
    }
}
