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

    /// The checker whose diagnostics describe the corpus rather than the code, and so are
    /// never violations. Spelled here rather than imported: `ConsistencyChecker` is downstream
    /// of this module, and depending on it to learn one string would invert the graph.
    static let auditorCheckerId = "consistency"

    private let writer: any CorpusTransport
    private let exemptions: [ConsistencyExemption]
    private let scorer: ConsistencyScorer

    /// Creates a new auditor.
    /// - Parameters:
    ///   - writer: The telemetry writer for Pulse I/O.
    ///   - exemptions: Documented exemptions to suppress specific findings.
    ///   - scorer: The consistency scorer. Defaults to one with default weights.
    public init(
        writer: any CorpusTransport,
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
        guard let pulse = try await writer.readLatestPulse(from: corpusPath, beforeWeek: nil) else {
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
        // Severity decides, not the enclosing checker's status. A checker can pass while
        // emitting warnings — `doc-lint` does — and those warnings are violations. Requiring
        // `status == .failed` made score impact depend on whether a checker chose to fail or
        // merely warn, which is a decision each checker makes for its own reasons and is
        // unrelated to how serious the finding is. A rule could be violated every run for
        // weeks without ever scoring.
        let violatedRuleIds = extractViolatedRuleIds(from: metadata.results)
        let checkerLookup = buildCheckerLookup(from: metadata.results)
        // Checker-level attribution still asks about *failure*: a checker that passed did not
        // fail, whatever it reported along the way. Anomalies are about checkers, so this is
        // the one place the status remains the right question.
        let failedCheckerIds = Set(metadata.results.filter { $0.status == .failed }.map(\.checkerId))

        var findings: [ConsistencyFinding] = []

        findings.append(contentsOf: matchClusters(
            failedRuleIds: violatedRuleIds,
            clusters: pulse.violationClusters,
            checkerLookup: checkerLookup
        ))

        findings.append(contentsOf: matchAnomalies(
            failedCheckerIds: failedCheckerIds,
            anomalies: pulse.statistics.anomalies
        ))

        findings.append(contentsOf: matchUnaddressedPolicies(
            failedRuleIds: violatedRuleIds,
            policies: pulse.proposedPolicyUpdates,
            checkerLookup: checkerLookup
        ))

        findings.append(contentsOf: detectSuppressionPatterns(
            metadata: metadata,
            clusters: pulse.violationClusters,
            checkerLookup: checkerLookup
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

    /// Rule ids this run actually violated.
    ///
    /// Severity is the only test. Two things it deliberately does **not** consult:
    ///
    /// The enclosing checker's *failure* is not a property of each diagnostic it emitted —
    /// `doc-code` failing on one compile error still prints its coverage note, and counting
    /// that note reported a rule as violated whose every occurrence is `note` and which is
    /// emitted when the checker *succeeds*.
    ///
    /// Nor is the checker's *success* a property of its diagnostics. `doc-lint` passes while
    /// emitting warnings; those are violations, and requiring `status == .failed` dropped them
    /// with the whole checker. That made score impact depend on whether a checker chose to fail
    /// or merely warn — a decision unrelated to how serious the finding is.
    ///
    /// Formerly `extractFailedRuleIds`, renamed because failure is no longer what it asks.
    private func extractViolatedRuleIds(from results: [CheckResult]) -> Set<String> {
        var ruleIds = Set<String>()
        // The auditor's own findings are excluded: a `consistency-finding.*` diagnostic reports
        // *on* violations and is not one. In the post-run path this is belt and braces — the
        // audit runs before its own result is appended, so it cannot see itself. In the
        // isolation path (`--check consistency`), which audits persisted telemetry, it can and
        // did: without this, it matches its own earlier finding and reports a finding about it.
        for result in results where result.checkerId != Self.auditorCheckerId {
            for diagnostic in result.diagnostics where diagnostic.isViolation {
                if let ruleId = diagnostic.ruleId {
                    ruleIds.insert(ruleId)
                }
            }
        }
        return ruleIds
    }

    /// Maps each violated rule id to the checker that reported it.
    ///
    /// Filtered identically to `extractFailedRuleIds` — a lookup built over a wider set than
    /// the ids it serves would attribute rules that never make it into a finding, and the two
    /// drifting apart is how the original counting bug stayed invisible.
    private func buildCheckerLookup(from results: [CheckResult]) -> [String: String] {
        var lookup: [String: String] = [:]
        for result in results {
            for diagnostic in result.diagnostics where diagnostic.isViolation {
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
