import Foundation
import QualityGateCore
import IJSSensor
import IJSAggregator
import IJSPolicyDiscovery

/// Checks institutional consistency by auditing the most recent telemetry
/// against the latest Pulse from the IJS corpus.
///
/// When the corpus is not configured or unreachable, returns `.passed`
/// with an informational note rather than failing.
public struct ConsistencyChecker: QualityChecker, Sendable {

    /// Unique identifier for this checker.
    public let id = "consistency"

    /// Human-readable name for this checker.
    public let name = "Institutional Consistency"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Institutional consistency scoring via IJS pulse and telemetry"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.specialty

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.institutional

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Creates a new consistency checker.
    public init() {}

    /// Which run a consistency result describes.
    ///
    /// The distinction is the point: a score printed inside a run reads as a statement about
    /// that run, and for a long time it was not one.
    enum AuditedRun: Sendable {
        /// The run that just completed, audited from its in-memory results.
        case current([CheckResult])
        /// No current run in scope — `--check consistency` in isolation. Falls back to the
        /// newest persisted telemetry, and says so.
        case newestPersisted
    }

    /// Audits the run that just completed.
    ///
    /// This is the entry point the CLI uses. `QualityChecker.check(configuration:)` receives
    /// only a `Configuration` — by design, and worth keeping — so a checker that needs the
    /// run's results cannot be a checker in the sweep. It becomes a post-run stage instead,
    /// which is the ADR this change carries: *a checker that audits a run must run after it.*
    ///
    /// - Parameters:
    ///   - results: Every `CheckResult` from this run, including skipped checkers.
    ///   - configuration: Project configuration.
    /// - Returns: A `CheckResult` describing this run's consistency with the institutional pulse.
    public func audit(
        results: [CheckResult],
        configuration: Configuration
    ) async throws -> CheckResult {
        try await evaluate(.current(results), configuration: configuration)
    }

    /// Runs the institutional consistency check against the IJS corpus.
    ///
    /// Retained for `--check consistency` in isolation, where there is no current run to audit.
    /// The lag is legitimate here rather than accidental — the caller asked for consistency
    /// alone — and the result says which run it read.
    public func check(configuration: Configuration) async throws -> CheckResult {
        try await evaluate(.newestPersisted, configuration: configuration)
    }

    private func evaluate(
        _ auditedRun: AuditedRun,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let config = configuration.consistency

        guard let corpusBasePath = config.corpusPath else {
            return makeResult(
                startTime: startTime,
                status: .passed,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "IJS corpus not configured — consistency check skipped",
                        ruleId: "consistency-unconfigured"
                    )
                ]
            )
        }

        guard FileManager.default.fileExists(atPath: corpusBasePath) else { // SAFETY: path from validated config, not user input
            return makeResult(
                startTime: startTime,
                status: .passed,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "IJS corpus directory not found at '\(corpusBasePath)' — consistency check skipped",
                        ruleId: "consistency-corpus-missing"
                    )
                ]
            )
        }

        let projectID = config.projectID
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent
        let corpus = CorpusPath(basePath: corpusBasePath, projectID: projectID)
        let writer = DirectCorpusTransport()

        guard let pulse = try await writer.readLatestPulse(from: corpus, beforeWeek: nil) else {
            return makeResult(
                startTime: startTime,
                status: .passed,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No institutional pulse found in corpus — consistency check skipped",
                        ruleId: "consistency-no-pulse"
                    )
                ]
            )
        }

        let now = Date()
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        let recentMetadata = try await writer.readMetadata(
            from: corpus,
            startDate: thirtyDaysAgo,
            endDate: now
        )

        let recentCalibrations = try await writer.readCalibrations(
            from: corpus,
            startDate: thirtyDaysAgo,
            endDate: now
        )

        // Which run is being audited, and the note that says so. The current run's telemetry
        // is written *after* every checker completes, so "newest on disk" is always the run
        // before — which is how a clean run reported the previous run's findings and the only
        // workaround was "run it again and believe the second answer".
        let latestMetadata: CheckResultMetadata
        let provenanceNote: Diagnostic
        switch auditedRun {
        case .current(let results):
            latestMetadata = CheckResultMetadata(
                projectID: projectID,
                timestamp: Date(),
                environment: ProcessInfo.processInfo.environment["CI"] != nil ? .ci : .local,
                // Both this audit and the record `TelemetryEmission` persists resolve ownership
                // through `IJSConfig.resolvedOwner`, so they cannot name different owners.
                decisionOwner: configuration.ijs.resolvedOwner(),
                results: results,
                overrides: [],
                riskTier: RiskTier(rawValue: config.defaultRiskTier) ?? .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
            provenanceNote = Diagnostic(
                severity: .note,
                message: "Auditing the current run.",
                ruleId: "consistency-audited-run"
            )

        case .newestPersisted:
            guard let newest = recentMetadata.sorted(by: { $0.timestamp > $1.timestamp }).first else {
                return makeResult(
                    startTime: startTime,
                    status: .passed,
                    diagnostics: [
                        Diagnostic(
                            severity: .note,
                            message: "Pulse found (\(pulse.weekLabel)) but no recent telemetry metadata — consistency check skipped",
                            ruleId: "consistency-no-metadata"
                        )
                    ]
                )
            }
            latestMetadata = newest
            provenanceNote = Diagnostic(
                severity: .note,
                message: "Auditing previous run \(ISO8601DateFormatter().string(from: newest.timestamp)) — no current run in scope.",
                ruleId: "consistency-audited-run"
            )
        }

        let scorer: ConsistencyScorer
        if let weights = config.scorerWeights {
            scorer = ConsistencyScorer(weights: ScorerWeights(
                clusterMatch: weights.clusterMatch,
                anomalyPattern: weights.anomalyPattern,
                unaddressedPolicy: weights.unaddressedPolicy,
                recurrenceBonus: weights.recurrenceBonus,
                suppressionPattern: weights.suppressionPattern
            ))
        } else {
            scorer = ConsistencyScorer()
        }

        let auditor = PolicyDiscoveryAuditor(writer: writer, scorer: scorer)
        let report = await auditor.audit(metadata: latestMetadata, against: pulse)

        // First, so a reader knows which run the findings below describe before reading them.
        var diagnostics: [Diagnostic] = [provenanceNote]

        for finding in report.findings {
            let severity: Diagnostic.Severity = finding.isRecurringInPulse ? .warning : .note
            diagnostics.append(Diagnostic(
                severity: severity,
                message: finding.explanation,
                ruleId: "consistency-finding.\(finding.matchType.rawValue)"
            ))
        }

        let scoreFormatted = report.consistencyScore.formatted(.number.precision(.fractionLength(2)))
        let thresholdFormatted = config.consistencyThreshold.formatted(.number.precision(.fractionLength(2)))
        diagnostics.append(Diagnostic(
            severity: .note,
            message: "Institutional consistency score: \(scoreFormatted) (threshold: \(thresholdFormatted), pulse: \(report.pulseWeekLabel), validity: \(report.baselineValidity))",
            ruleId: "consistency-score"
        ))

        diagnostics.append(contentsOf: calibrationRecommendations(
            metadata: recentMetadata,
            calibrations: recentCalibrations
        ))

        let status: CheckResult.Status = report.consistencyScore < config.consistencyThreshold
            ? .warning
            : .passed

        return makeResult(startTime: startTime, status: status, diagnostics: diagnostics)
    }

    private static let minimumSampleCount = 30
    private static let falsePositiveThreshold = 0.5

    private func calibrationRecommendations(
        metadata: [CheckResultMetadata],
        calibrations: [JudgmentCalibration]
    ) -> [Diagnostic] {
        var samplesByChecker: [String: Int] = [:]
        for entry in metadata {
            for result in entry.results {
                samplesByChecker[result.checkerId, default: 0] += 1
            }
        }

        var totalByChecker: [String: Int] = [:]
        var impreciseByChecker: [String: Int] = [:]

        for calibration in calibrations {
            let proximate = calibration.rootCauseAnalysis.proximateCause
            guard proximate.hasPrefix("Override of ") else { continue }
            let afterPrefix = proximate.dropFirst("Override of ".count)
            guard let colonIndex = afterPrefix.firstIndex(of: ":") else { continue }
            let ruleId = String(afterPrefix[afterPrefix.startIndex..<colonIndex])
            guard let dotIndex = ruleId.firstIndex(of: ".") else { continue }
            let checkerId = String(ruleId[ruleId.startIndex..<dotIndex])

            totalByChecker[checkerId, default: 0] += 1
            if calibration.rootCauseAnalysis.rootCause == "imprecise" {
                impreciseByChecker[checkerId, default: 0] += 1
            }
        }

        var results: [Diagnostic] = []

        for (checkerId, sampleCount) in samplesByChecker where sampleCount >= Self.minimumSampleCount {
            guard let total = totalByChecker[checkerId], total > 0 else { continue }
            let imprecise = impreciseByChecker[checkerId] ?? 0
            let fpRate = Double(imprecise) / Double(total)
            guard fpRate > Self.falsePositiveThreshold else { continue }

            let fpPercent = Int((fpRate * 100).rounded())
            results.append(Diagnostic(
                severity: .note,
                message: "Checker '\(checkerId)' has a \(fpPercent)% false positive rate across \(sampleCount) runs. Consider tuning the checker or adding exemption patterns.",
                ruleId: "calibration-recommended"
            ))
        }

        return results
    }

    private func makeResult(
        startTime: ContinuousClock.Instant,
        status: CheckResult.Status,
        diagnostics: [Diagnostic]
    ) -> CheckResult {
        CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - startTime
        )
    }
}
