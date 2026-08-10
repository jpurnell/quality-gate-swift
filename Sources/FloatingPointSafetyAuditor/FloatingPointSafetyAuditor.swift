import Foundation
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

    /// Creates a floating-point safety auditor.
    public init() {}

    /// Audits all Swift files under the `Sources/` directory for floating-point
    /// safety violations.
    ///
    /// - Parameter configuration: Project-specific configuration including
    ///   `fpSafety` settings.
    /// - Returns: A `CheckResult` with status `.warning` if diagnostics were
    ///   found, `.passed` otherwise.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []
        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let result = auditDirectory(
                at: sourcesPath,
                config: configuration.fpSafety
            )
            allDiagnostics.append(contentsOf: result.diagnostics)
            allOverrides.append(contentsOf: result.overrides)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .warning
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

    private func auditDirectory(
        at path: String,
        config: FloatingPointSafetyAuditorConfig
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else { return ([], []) }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            // Skip allowed files
            if config.allowedFiles.contains(where: { relativePath.contains($0) }) {
                continue
            }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)
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
