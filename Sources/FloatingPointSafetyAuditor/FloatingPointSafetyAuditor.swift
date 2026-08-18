import Foundation
import IndexStoreInfra
#if canImport(os)
import os
#endif
import QualityGateCore

/// Scans Swift source for floating-point safety issues.
///
/// Detected rules:
/// - `fp-equality` — exact `==` / `!=` comparison on floating-point operands
/// - `fp-division-unguarded` — division by a floating-point value without a
///   visible zero guard in the enclosing scope
///
/// Both rules emit warnings (not errors) because heuristic detection from
/// syntax alone cannot guarantee the operand types. False positives are
/// preferable to silent precision bugs.
///
/// ## Configuration
///
/// Use `FloatingPointSafetyAuditorConfig` to control behavior:
/// - `allowedFiles` — file paths to skip entirely
/// - `checkDivisionGuards` — enable/disable the `fp-division-unguarded` rule
///
/// ## Suppression
///
/// Add `// fp-safety:disable` on a source line — or on the comment line
/// immediately above it — to suppress FP diagnostics for that line. A line
/// containing only the marker disables the file. The legacy `// TEST-QUALITY:`
/// marker is honoured too: `fp-equality` and `exact-double-equality` are one
/// rule, so one marker set silences it from either checker. See
/// ``FloatingPointSuppression``.
public struct FloatingPointSafetyAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "FloatingPointSafetyAuditor")

    /// Unique identifier for this checker.
    public let id = "fp-safety"
    /// Human-readable display name for this checker.
    public let name = "Floating-Point Safety Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Floating-point exact equality, unguarded division"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Creates a floating-point safety auditor.
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

    /// Audits all Swift files under the `Sources/` directory for floating-point
    /// safety violations.
    ///
    /// - Parameter configuration: Project-specific configuration including
    ///   `fpSafety` settings.
    /// - Returns: A `CheckResult` with status `.warning` if diagnostics were
    ///   found, `.passed` otherwise.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let root = configuration.resolvedProjectRoot
        // Hardcoded `Sources/` before this. The project's own rule names tests explicitly —
        // "Tests: never use == for floating point" — and the checker that enforces it was
        // never pointed at `Tests/`. `SourceWalker` also brings the `excludePatterns` the
        // private enumerator ignored.
        let scan = SourceWalker.walk(under: root, excludePatterns: configuration.excludePatterns)

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []
        let result = auditFiles(
            scan.files,
            relativeTo: root.resolvingSymlinksInPath().path,
            config: configuration.fpSafety
        )
        allDiagnostics.append(contentsOf: result.diagnostics)
        allOverrides.append(contentsOf: result.overrides)

        // Emitted pass or fail — examined-nothing must not look like found-nothing.
        let plural = scan.files.count == 1 ? "" : "s"
        allDiagnostics.append(Diagnostic(
            severity: .note,
            message: "floating-point examined \(scan.files.count) file\(plural)"
                + (scan.exclusionClause.map { " · \($0)" } ?? ""),
            ruleId: "fp-safety.coverage"))

        let duration = ContinuousClock.now - startTime
        // Notes excluded: this checker reports at `.warning`, so an `isEmpty` test would both
        // fail on its own coverage note and, if written as "any `.error`", pass a file holding
        // the very unguarded division it exists to find.
        let status: CheckResult.Status = allDiagnostics.contains { $0.severity != .note } ? .warning : .passed
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            overrides: allOverrides,
            duration: duration
        )
    }

    /// Audits a single source string for floating-point safety issues.
    ///
    /// Useful for testing or single-file analysis without filesystem access.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to analyze.
    ///   - fileName: The file path used in emitted diagnostics.
    ///   - configuration: The quality-gate configuration.
    /// - Returns: A `CheckResult` with all diagnostics found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let result = auditSourceCode(
            source,
            fileName: fileName,
            config: configuration.fpSafety
        )
        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = result.diagnostics.isEmpty ? .passed : .warning
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: result.diagnostics,
            overrides: result.overrides,
            duration: duration
        )
    }

    // MARK: - Private

    /// Audits an already-scoped list of Swift files; the walk decides what the run owns.
    ///
    /// - Parameter root: The package root, used to re-derive each file's repository-relative
    ///   path. `allowedFiles` is matched against that rather than against the absolute path:
    ///   an absolute path carries the checkout's own directory names, so matching it would let
    ///   an entry like `Metrics` start excluding files because somebody's home directory
    ///   happened to contain the word.
    private func auditFiles(
        _ paths: [String],
        relativeTo root: String,
        config: FloatingPointSafetyAuditorConfig
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        for fullPath in paths {
            let relativePath = fullPath.hasPrefix(root)
                ? String(fullPath.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : fullPath

            // Skip allowed files
            if config.allowedFiles.contains(where: { relativePath.contains($0) }) {
                continue
            }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSourceCode(source, fileName: fullPath, config: config)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                Self.logger.warning("Failed to read source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        return (diagnostics, overrides)
    }

    /// Delegates to the shared rule implementation. `fp-equality` and
    /// `exact-double-equality` are one rule; this checker supplies the
    /// `Sources/` reporting configuration for it.
    private func auditSourceCode(
        _ source: String,
        fileName: String,
        config: FloatingPointSafetyAuditorConfig
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        FloatingPointRules.audit(
            source: source,
            fileName: fileName,
            options: .sources(checkDivisionGuards: config.checkDivisionGuards)
        )
    }
}
