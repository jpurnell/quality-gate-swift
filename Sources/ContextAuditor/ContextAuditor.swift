import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
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
    private static let logger = Logger(subsystem: "com.quality-gate", category: "ContextAuditor")

    /// Unique identifier for this checker.
    public let id = "context"

    /// Human-readable name for this checker.
    public let name = "Context Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Missing consent guards, unguarded analytics, surveillance patterns"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.codeHygiene

    /// What this checker's findings are about — see `CheckerKind`.
    /// scans source, but reports a values judgment — presumptuous on code we do not own
    public let kind = CheckerKind.convention

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Creates a new ContextAuditor instance.
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

    /// Run the context audit on the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let root = configuration.resolvedProjectRoot
        // Hardcoded `Sources/` before this. The `isTestFile` skip inside the walk is a
        // separate, deliberate judgement and survives; the directory bound was not.
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)

        var allDiagnostics: [Diagnostic] = []
        allDiagnostics = try await auditFiles(scan.files, configuration: configuration)

        // Emitted pass or fail — examined-nothing must not look like found-nothing.
        let plural = scan.files.count == 1 ? "" : "s"
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "context examined \(scan.files.count) file\(plural)"
                + (scan.exclusionClause.map { " · \($0)" } ?? ""),
            ruleId: "context.coverage"))

        let duration = ContinuousClock.now - startTime
        // Notes excluded: an `isEmpty` test would warn on every run once the note exists.
        let status: CheckResult.Status = allDiagnostics.contains { $0.severity != .note } ? .warning : .passed

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

    /// Audits an already-scoped list of Swift files; the walk decides what the run owns.
    ///
    /// The `isTestFile` skip is kept and is a different thing from the hardcoded `Sources/`
    /// this used to be bounded by: that was where the enumerator happened to be pointed, this
    /// is a stated judgement about what the rule means.
    private func auditFiles(
        _ paths: [String],
        configuration: Configuration
    ) async throws -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for fullPath in paths {
            if isTestFile(fullPath) { continue }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                diagnostics.append(contentsOf: auditSourceCode(source, fileName: fullPath))
            } catch {
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
