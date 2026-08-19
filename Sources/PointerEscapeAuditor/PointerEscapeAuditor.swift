import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for `Unsafe*Pointer` values that escape the
/// `withUnsafe*` closure scope that owns their underlying memory.
///
/// See `PointerEscapeAuditorGuide.md` for the full rule list and the
/// canonical Accelerate FFT incident that motivated each rule.
public struct PointerEscapeAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "PointerEscapeAuditor")
    /// Unique identifier for this checker, used in diagnostics and configuration.
    public let id = "pointer-escape"
    /// Human-readable display name for this checker.
    public let name = "Pointer Escape Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Unsafe pointer escapes from `withUnsafe*` blocks"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Function names whose pointer-accepting parameters are documented as
    /// safe to outlive the with-block (e.g. specific vDSP entry points).
    private let allowedEscapeFunctions: Set<String>

    /// Creates a pointer-escape auditor.
    /// - Parameter allowedEscapeFunctions: Function names whose pointer parameters are safe to outlive the with-block.
    public init(allowedEscapeFunctions: Set<String> = []) {
        self.allowedEscapeFunctions = allowedEscapeFunctions
    }

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

    /// Scans all Swift files under the project `Sources/` directory for pointer escapes.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        // Hardcoded `Sources/` before this: a pointer escaping a `withUnsafe*` block in
        // `Plugins/`, `Tests/`, or at the package root was never looked at, and a dangling
        // pointer in a test is a crash in the suite. `SourceWalker` also applies the
        // `excludePatterns` the private enumerator never consulted.
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []
        var allCompliance: [ComplianceRecord] = []
        let result = auditFiles(scan.files)
        allDiagnostics.append(contentsOf: result.diagnostics)
        allOverrides.append(contentsOf: result.overrides)
        allCompliance.append(contentsOf: result.complianceRecords)

        // Emitted pass or fail — a checker that examined nothing must not print what a checker
        // that found nothing prints.
        let plural = scan.files.count == 1 ? "" : "s"
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "pointer-escape examined \(scan.files.count) file\(plural)"
                + (scan.exclusionClause.map { " · \($0)" } ?? ""),
            ruleId: "pointer-escape.coverage"))

        let duration = ContinuousClock.now - startTime
        // Notes excluded deliberately: the coverage note above is a diagnostic, and testing
        // `allDiagnostics.isEmpty` would make every run fail the moment it was added.
        let status: CheckResult.Status = allDiagnostics.contains { $0.severity != .note } ? .failed : .passed
        return CheckResult(checkerId: id, status: status, diagnostics: allDiagnostics, overrides: allOverrides, complianceRecords: allCompliance, duration: duration)
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
        return CheckResult(checkerId: id, status: status, diagnostics: result.diagnostics, overrides: result.overrides, complianceRecords: result.complianceRecords, duration: duration)
    }

    // MARK: - Private

    /// Audits an already-scoped list of Swift files; the walk decides what the run owns.
    private func auditFiles(_ paths: [String]) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride], complianceRecords: [ComplianceRecord]) {
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        var complianceRecords: [ComplianceRecord] = []
        for fullPath in paths {
            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSourceCode(source, fileName: fullPath)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
                complianceRecords.append(contentsOf: result.complianceRecords)
            } catch {
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        return (diagnostics, overrides, complianceRecords)
    }

    private func auditSourceCode(_ source: String, fileName: String) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride], complianceRecords: [ComplianceRecord]) {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = PointerEscapeVisitor(
            fileName: fileName,
            converter: converter,
            allowedEscapeFunctions: allowedEscapeFunctions,
            sourceText: source
        )
        visitor.walk(tree)
        return (visitor.diagnostics, visitor.overrides, visitor.complianceRecords)
    }
}
