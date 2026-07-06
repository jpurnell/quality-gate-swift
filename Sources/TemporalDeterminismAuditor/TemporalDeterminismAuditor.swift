import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift source for hidden nondeterminism sourced from wall-clock time.
///
/// This is the temporal analog of the ``StochasticDeterminismAuditor``: where
/// that auditor bans nondeterminism from randomness, this one bans
/// nondeterminism from reading the wall clock in places where results must be
/// reproducible.
///
/// Detected rules:
/// - `temporal-simulated-wall-clock` — a simulation/synthetic/mock type stamps a
///   wall-clock read (`ContinuousClock.now`, `Date()`, …) as a timestamp value.
///   Simulated data must derive time from a logical origin, or its output
///   spacing tracks scheduler jitter instead of the intended interval.
/// - `temporal-wall-clock-assertion` — a test asserts on *measured elapsed
///   wall-clock time* against a numeric threshold, which flakes under load.
///
/// ## Suppression
///
/// Add `// temporal:exempt` on a source line to suppress temporal diagnostics on
/// that line. Add `// TIMING:` on an assertion line to declare an intentional
/// wall-clock performance test (exempts `temporal-wall-clock-assertion`).
public struct TemporalDeterminismAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "TemporalDeterminismAuditor")

    /// Unique identifier for this checker.
    public let id = "temporal-determinism"
    /// Human-readable display name for this checker.
    public let name = "Temporal Determinism Auditor"

    /// Creates a temporal determinism auditor.
    public init() {}

    /// Audits `Sources/` (production rule) and `Tests/` (assertion rule) for
    /// wall-clock nondeterminism.
    ///
    /// - Parameter configuration: Project configuration including
    ///   `temporalDeterminism` settings.
    /// - Returns: A `CheckResult` with status `.warning` if diagnostics were
    ///   found, `.passed` otherwise.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let config = configuration.temporalDeterminism

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        for dir in ["Sources", "Tests"] {
            let path = (currentDir as NSString).appendingPathComponent(dir)
            guard fileManager.fileExists(atPath: path) else { continue } // SAFETY: CLI reads local project dirs from cwd
            let result = auditDirectory(at: path, config: config)
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

    /// Audits a single source string. Useful for testing or single-file analysis
    /// without filesystem access. The `fileName` determines which rule runs:
    /// a path containing `/Tests/` runs the assertion rule, otherwise the
    /// simulated-source rule.
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
        let result = auditSourceCode(source, fileName: fileName, config: configuration.temporalDeterminism)
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
        config: TemporalDeterminismConfig
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        guard let enumerator = fileManager.enumerator(atPath: path) else { return ([], []) }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (path as NSString).appendingPathComponent(relativePath)
            if config.exemptFiles.contains(where: { fullPath.contains($0) }) { continue }
            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSourceCode(source, fileName: fullPath, config: config)
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                Self.logger.warning("Skipping unreadable source file \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        return (diagnostics, overrides)
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        config: TemporalDeterminismConfig
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let sourceLines = source.components(separatedBy: "\n")
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = TemporalVisitor(
            filePath: fileName,
            converter: converter,
            sourceLines: sourceLines,
            config: config
        )
        visitor.walk(tree)
        return (visitor.diagnostics, visitor.overrides)
    }
}
