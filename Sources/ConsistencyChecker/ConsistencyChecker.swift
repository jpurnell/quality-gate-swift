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

    /// Creates a new consistency checker.
    public init() {}

    /// Runs the institutional consistency check against the IJS corpus.
    public func check(configuration: Configuration) async throws -> CheckResult {
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
        let writer = TelemetryWriter()

        guard let pulse = try await writer.readLatestPulse(from: corpus) else {
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

        guard let latestMetadata = recentMetadata.sorted(by: { $0.timestamp > $1.timestamp }).first else {
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

        let scorer: ConsistencyScorer
        if let weights = config.scorerWeights {
            scorer = ConsistencyScorer(weights: ScorerWeights(
                clusterMatch: weights.clusterMatch,
                anomalyPattern: weights.anomalyPattern,
                unaddressedPolicy: weights.unaddressedPolicy,
                recurrenceBonus: weights.recurrenceBonus
            ))
        } else {
            scorer = ConsistencyScorer()
        }

        let auditor = PolicyDiscoveryAuditor(writer: writer, scorer: scorer)
        let report = await auditor.audit(metadata: latestMetadata, against: pulse)

        var diagnostics: [Diagnostic] = []

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

        let status: CheckResult.Status = report.consistencyScore < config.consistencyThreshold
            ? .warning
            : .passed

        return makeResult(startTime: startTime, status: status, diagnostics: diagnostics)
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
