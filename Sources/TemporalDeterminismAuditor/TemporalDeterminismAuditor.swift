import Foundation
import QualityGateCore

/// The quality-gate adapter for VigilKit's temporal-determinism engine.
///
/// The analysis itself — `TemporalVisitor`, `TemporalScan`, and
/// `TemporalDeterminismConfig` — lives in swift-vigil (Phase 4 extraction,
/// move-not-fork: one implementation, two products; this monolith is
/// downstream of the extraction). This wrapper binds the engine to the
/// `QualityChecker` protocol and the gate's `Configuration`.
///
/// Rules and suppression markers are documented on `TemporalScan`.
public struct TemporalDeterminismAuditor: QualityChecker, Sendable {
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
        let scan = TemporalScan.scanDirectories(
            root: FileManager.default.currentDirectoryPath,
            config: configuration.temporalDeterminism
        )
        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = scan.findings.diagnostics.isEmpty ? .passed : .warning
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: scan.findings.diagnostics,
            overrides: scan.findings.overrides,
            duration: duration
        )
    }

    /// Audits a single source string. Useful for testing or single-file
    /// analysis without filesystem access. The `fileName` determines which
    /// rule runs: a path containing `/Tests/` runs the assertion rule,
    /// otherwise the simulated-source rule.
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
        let findings = TemporalScan.scanSource(
            source, fileName: fileName, config: configuration.temporalDeterminism)
        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = findings.diagnostics.isEmpty ? .passed : .warning
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: findings.diagnostics,
            overrides: findings.overrides,
            duration: duration
        )
    }
}
