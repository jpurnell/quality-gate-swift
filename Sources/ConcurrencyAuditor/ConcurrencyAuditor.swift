import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for Swift 6 concurrency bugs and dangerous escape hatches.
///
/// Detected rules (see `ConcurrencyAuditorGuide.md` for full discussion):
/// - `concurrency.unchecked-sendable-no-justification`
/// - `concurrency.nonisolated-unsafe-no-justification`
/// - `concurrency.sendable-class-mutable-state`
/// - `concurrency.sendable-class-non-sendable-property`
/// - `concurrency.task-captures-self-no-isolation`
/// - `concurrency.dispatch-queue-in-actor`
/// - `concurrency.main-actor-deinit-touches-state`
/// - `concurrency.preconcurrency-first-party-import`
public struct ConcurrencyAuditor: QualityChecker, Sendable {
    public let id = "concurrency"
    public let name = "Concurrency Auditor"

    /// First-party module names (parsed from Package.swift). Empty in single-file mode.
    private let firstPartyModules: Set<String>
    /// Allowlist of modules that may use `@preconcurrency` even if first-party.
    private let allowPreconcurrencyImports: Set<String>
    /// Keyword that identifies a justification comment (e.g. "Justification:").
    private let justificationKeyword: String

    public init(
        firstPartyModules: Set<String> = [],
        allowPreconcurrencyImports: Set<String> = [],
        justificationKeyword: String = "Justification:"
    ) {
        self.firstPartyModules = firstPartyModules
        self.allowPreconcurrencyImports = allowPreconcurrencyImports
        self.justificationKeyword = justificationKeyword
    }

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

    /// Single-file audit. The `preconcurrency-first-party-import` rule is skipped
    /// in this mode unless `firstPartyModules` was supplied at init time.
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
        let sourceLines = source.components(separatedBy: "\n")
        let visitor = ConcurrencyVisitor(
            fileName: fileName,
            converter: converter,
            sourceLines: sourceLines,
            firstPartyModules: firstPartyModules,
            allowPreconcurrencyImports: allowPreconcurrencyImports,
            justificationKeyword: justificationKeyword
        )
        visitor.walk(tree)
        return (visitor.diagnostics, visitor.overrides)
    }
}
