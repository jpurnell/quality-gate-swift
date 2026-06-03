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

        let recentCalibrations = try await writer.readCalibrations(
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
                recurrenceBonus: weights.recurrenceBonus,
                suppressionPattern: weights.suppressionPattern
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
