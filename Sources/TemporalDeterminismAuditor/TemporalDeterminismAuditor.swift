import Foundation
import IndexStoreInfra
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

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Wall-clock nondeterminism: simulated sources stamping `.now`, and tests asserting on measured elapsed wall-clock time"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Creates a temporal determinism auditor.
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
            root: configuration.resolvedProjectRoot.path,
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
