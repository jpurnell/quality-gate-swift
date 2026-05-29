import Foundation
import QualityGateTypes
import IJSSensor
import IJSAggregator
import IJSRefiner

/// Compares current gate results against the most recent InstitutionalPulse
/// to detect institutional inconsistencies.
///
/// Reads the latest Pulse via TelemetryWriter (maintaining the I/O ownership
/// invariant) and matches current failures against known ViolationClusters,
/// anomaly patterns, and unaddressed policy proposals.
public actor PolicyDiscoveryAuditor {

    private let writer: TelemetryWriter
    private let exemptions: [ConsistencyExemption]
    private let scorer: ConsistencyScorer

    /// Creates a new auditor.
    /// - Parameters:
    ///   - writer: The telemetry writer for Pulse I/O.
    ///   - exemptions: Documented exemptions to suppress specific findings.
    ///   - scorer: The consistency scorer. Defaults to one with default weights.
    public init(
        writer: TelemetryWriter,
        exemptions: [ConsistencyExemption] = [],
        scorer: ConsistencyScorer = ConsistencyScorer()
    ) {
        self.writer = writer
        self.exemptions = exemptions
        self.scorer = scorer
    }

    /// Audits a gate run against the most recent Pulse.
    ///
    /// Returns a report with empty findings and score 1.0 if no Pulse exists.
    public func audit(
        metadata: CheckResultMetadata,
        against corpusPath: CorpusPath
    ) async throws -> ConsistencyReport {
        guard let pulse = try await writer.readLatestPulse(from: corpusPath) else {
            return ConsistencyReport(
                projectID: metadata.projectID,
                timestamp: metadata.timestamp,
                pulseWeekLabel: "none",
                findings: [],
                consistencyScore: 1.0,
                baselineValidity: .insufficient
            )
        }
        return audit(metadata: metadata, against: pulse)
    }

    /// Audits a gate run against a specific Pulse.
    public func audit(
        metadata: CheckResultMetadata,
        against pulse: InstitutionalPulse
    ) -> ConsistencyReport {
        let failedResults = metadata.results.filter { $0.status == .failed }
        let failedRuleIds = extractFailedRuleIds(from: failedResults)
        let failedCheckerIds = Set(failedResults.map(\.checkerId))

        var findings: [ConsistencyFinding] = []

        findings.append(contentsOf: matchClusters(
            failedRuleIds: failedRuleIds,
            clusters: pulse.violationClusters,
            checkerLookup: buildCheckerLookup(from: failedResults)
        ))

        findings.append(contentsOf: matchAnomalies(
            failedCheckerIds: failedCheckerIds,
            anomalies: pulse.statistics.anomalies
        ))

        findings.append(contentsOf: matchUnaddressedPolicies(
            failedRuleIds: failedRuleIds,
            policies: pulse.proposedPolicyUpdates,
            checkerLookup: buildCheckerLookup(from: failedResults)
        ))

        findings.append(contentsOf: detectSuppressionPatterns(
            metadata: metadata,
            clusters: pulse.violationClusters,
            checkerLookup: buildCheckerLookup(from: failedResults)
        ))

        let baselineValidity = inferBaselineValidity(from: pulse)
        let score = scorer.score(findings: findings, baselineValidity: baselineValidity)

        return ConsistencyReport(
            projectID: metadata.projectID,
            timestamp: metadata.timestamp,
            pulseWeekLabel: pulse.weekLabel,
            findings: findings,
            consistencyScore: score,
            baselineValidity: baselineValidity
        )
    }

    // MARK: - Matching

    private func matchClusters(
        failedRuleIds: Set<String>,
        clusters: [ViolationCluster],
        checkerLookup: [String: String]
    ) -> [ConsistencyFinding] {
        var findings: [ConsistencyFinding] = []
        for cluster in clusters {
            guard failedRuleIds.contains(cluster.ruleId) else { continue }
            guard !isExempted(ruleId: cluster.ruleId, matchType: .clusterMatch) else { continue }

            findings.append(ConsistencyFinding(
                ruleId: cluster.ruleId,
                checkerId: checkerLookup[cluster.ruleId] ?? "unknown",
                matchType: .clusterMatch,
                clusterRiskWeight: Double(cluster.occurrenceCount) / 10.0,
                historicalOccurrences: cluster.occurrenceCount,
                isRecurringInPulse: cluster.isRecurring,
                explanation: "Rule '\(cluster.ruleId)' matched ViolationCluster with \(cluster.occurrenceCount) occurrences"
            ))
        }
        return findings
    }

    /// Detects clusters where violations were reduced primarily through overrides
    /// rather than actual code fixes.
    ///
    /// For each cluster with `priorOccurrenceCount`, computes the ratio of
    /// fixes to total reduction (fixes + new overrides). If the resolution rate
    /// is below 0.5 and there are at least 2 new overrides, emits a finding.
    private func detectSuppressionPatterns(
        metadata: CheckResultMetadata,
        clusters: [ViolationCluster],
        checkerLookup: [String: String]
    ) -> [ConsistencyFinding] {
        var findings: [ConsistencyFinding] = []
        let overridesByRule = Dictionary(
            grouping: metadata.overrides,
            by: \.diagnosticOverride.ruleId
        )

        for cluster in clusters {
            guard let priorCount = cluster.priorOccurrenceCount else { continue }
            guard !isExempted(ruleId: cluster.ruleId, matchType: .suppressionPattern) else { continue }

            let currentCount = cluster.occurrenceCount
            let overrideCount = overridesByRule[cluster.ruleId]?.count ?? 0

            let reductionFromFixes = max(0, priorCount - currentCount)
            let totalReduction = reductionFromFixes + overrideCount

            // fp-safety: guarded by totalReduction > 0 check
            let resolutionRate: Double = totalReduction > 0
                ? Double(reductionFromFixes) / Double(totalReduction)
                : 1.0

            guard resolutionRate < 0.5, overrideCount >= 2 else { continue }

            let rateFormatted = resolutionRate.formatted(.number.precision(.fractionLength(2)))
            findings.append(ConsistencyFinding(
                ruleId: cluster.ruleId,
                checkerId: checkerLookup[cluster.ruleId] ?? "unknown",
                matchType: .suppressionPattern,
                clusterRiskWeight: Double(cluster.occurrenceCount) / 10.0,
                historicalOccurrences: cluster.occurrenceCount,
                isRecurringInPulse: cluster.isRecurring,
                explanation: "Rule '\(cluster.ruleId)' reduced from \(priorCount) to \(currentCount) violations with \(overrideCount) overrides — resolution rate \(rateFormatted) indicates suppression over fixing"
            ))
        }
        return findings
    }

    private func matchAnomalies(
        failedCheckerIds: Set<String>,
        anomalies: [StatisticalAnomaly]
    ) -> [ConsistencyFinding] {
        var findings: [ConsistencyFinding] = []
        for anomaly in anomalies {
            guard anomaly.direction == .negative else { continue }

            for checkerId in failedCheckerIds {
                guard anomaly.metric.contains(checkerId) else { continue }
                guard !isExempted(ruleId: checkerId, matchType: .anomalyPattern) else { continue }

                findings.append(ConsistencyFinding(
                    ruleId: checkerId,
                    checkerId: checkerId,
                    matchType: .anomalyPattern,
                    clusterRiskWeight: abs(anomaly.zScore) / 5.0,
                    historicalOccurrences: 1,
                    isRecurringInPulse: false,
                    explanation: "Checker '\(checkerId)' failed during negative anomaly in '\(anomaly.metric)' (z=\(anomaly.zScore.formatted(.number.precision(.fractionLength(2)))))"
                ))
            }
        }
        return findings
    }

    private func matchUnaddressedPolicies(
        failedRuleIds: Set<String>,
        policies: [String],
        checkerLookup: [String: String]
    ) -> [ConsistencyFinding] {
        var findings: [ConsistencyFinding] = []
        for ruleId in failedRuleIds {
            let matchingPolicies = policies.filter { $0.contains(ruleId) }
            guard !matchingPolicies.isEmpty else { continue }
            guard !isExempted(ruleId: ruleId, matchType: .unaddressedPolicy) else { continue }

            findings.append(ConsistencyFinding(
                ruleId: ruleId,
                checkerId: checkerLookup[ruleId] ?? "unknown",
                matchType: .unaddressedPolicy,
                clusterRiskWeight: 0.1,
                historicalOccurrences: matchingPolicies.count,
                isRecurringInPulse: false,
                explanation: "Rule '\(ruleId)' still failing with \(matchingPolicies.count) unaddressed policy proposal(s)"
            ))
        }
        return findings
    }

    // MARK: - Helpers

    private func extractFailedRuleIds(from results: [CheckResult]) -> Set<String> {
        var ruleIds = Set<String>()
        for result in results {
            for diagnostic in result.diagnostics {
                if let ruleId = diagnostic.ruleId {
                    ruleIds.insert(ruleId)
                }
            }
        }
        return ruleIds
    }

    private func buildCheckerLookup(from results: [CheckResult]) -> [String: String] {
        var lookup: [String: String] = [:]
        for result in results {
            for diagnostic in result.diagnostics {
                if let ruleId = diagnostic.ruleId {
                    lookup[ruleId] = result.checkerId
                }
            }
        }
        return lookup
    }

    private func isExempted(ruleId: String, matchType: ConsistencyMatchType) -> Bool {
        exemptions.contains { exemption in
            exemption.ruleId == ruleId &&
            (exemption.matchType == nil || exemption.matchType == matchType)
        }
    }

    private func inferBaselineValidity(from pulse: InstitutionalPulse) -> StatisticalValidity {
        guard pulse.statistics.totalGateRuns >= 30 else {
            guard pulse.statistics.totalGateRuns >= 3 else {
                return .insufficient
            }
            return .preliminary
        }
        return .valid
    }
}
