import Testing
import Foundation
import QualityGateTypes
@testable import IJSPolicyDiscovery
import IJSSensor
import IJSAggregator

@Suite("PolicyDiscoveryAuditor")
struct PolicyDiscoveryAuditorTests {

    private let scorer = ConsistencyScorer()

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeMetadata(
        projectID: String = "test-project",
        results: [CheckResult] = []
    ) -> CheckResultMetadata {
        CheckResultMetadata(
            projectID: projectID,
            timestamp: makeDate("2026-04-28"),
            environment: .local,
            decisionOwner: "jpurnell",
            results: results,
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil
        )
    }

    private func makeFailedResult(
        checkerId: String = "ConcurrencyAuditor",
        ruleId: String = "concurrency.unchecked-sendable"
    ) -> CheckResult {
        CheckResult(
            checkerId: checkerId,
            status: .failed,
            diagnostics: [
                Diagnostic(
                    severity: .error,
                    message: "Test diagnostic",
                    ruleId: ruleId
                )
            ],
            duration: .seconds(1)
        )
    }

    private func makePassingResult(checkerId: String = "SafetyAuditor") -> CheckResult {
        CheckResult(
            checkerId: checkerId,
            status: .passed,
            diagnostics: [],
            duration: .seconds(1)
        )
    }

    private func makePulse(
        weekLabel: String = "2026-W17",
        violationClusters: [ViolationCluster] = [],
        anomalies: [StatisticalAnomaly] = [],
        proposedPolicyUpdates: [String] = []
    ) -> InstitutionalPulse {
        let stats = PulseStatistics(
            totalGateRuns: 10,
            passedRuns: 8,
            failedRuns: 2,
            totalOverrides: 1,
            totalCalibrations: 1,
            overridesByRiskTier: [:],
            failuresByChecker: [:],
            rootCauseDistribution: [:],
            failedStepDistribution: [:],
            meanConsistencyScore: nil,
            corpusTrends: [],
            projectTrends: [:],
            anomalies: anomalies,
            corpusSnapshots: [],
            projectSnapshots: [:]
        )

        return InstitutionalPulse(
            windowStart: makeDate("2026-04-21"),
            windowEnd: makeDate("2026-04-28"),
            weekLabel: weekLabel,
            projects: ["test-project"],
            statistics: stats,
            violationClusters: violationClusters,
            proposedPolicyUpdates: proposedPolicyUpdates,
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: makeDate("2026-04-28")
        )
    }

    private func makeCluster(
        ruleId: String = "concurrency.unchecked-sendable",
        occurrenceCount: Int = 5,
        isRecurring: Bool = true
    ) -> ViolationCluster {
        ViolationCluster(
            ruleId: ruleId,
            occurrenceCount: occurrenceCount,
            affectedProjectCount: 1,
            dominantRootCause: "systemic",
            dominantFailedStep: .diagnosis,
            isRecurring: isRecurring
        )
    }

    private func makeAnomaly(
        metric: String = "failedRuns",
        direction: AnomalyDirection = .negative
    ) -> StatisticalAnomaly {
        StatisticalAnomaly(
            metric: metric,
            observedValue: 8.0,
            expectedValue: 2.0,
            zScore: 3.5,
            severity: .extreme,
            date: makeDate("2026-04-27"),
            scope: "test-project",
            direction: direction,
            baselineValidity: .valid
        )
    }

    // MARK: - No Pulse (Graceful Degradation)

    @Test("No pulse returns empty findings and score 1.0")
    func noPulseGracefulDegradation() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let corpus = CorpusPath(
            basePath: FileManager.default.temporaryDirectory
                .appendingPathComponent("ijs-auditor-test-\(UUID().uuidString)").path,
            projectID: "test-project"
        )
        let metadata = makeMetadata(results: [makeFailedResult()])

        let report = try await auditor.audit(metadata: metadata, against: corpus)
        #expect(report.findings.isEmpty)
        #expect(abs(report.consistencyScore - 1.0) < 1e-6)
        #expect(report.projectID == "test-project")
    }

    // MARK: - Cluster Matching

    @Test("Cluster match: failed ruleId matching ViolationCluster produces finding")
    func clusterMatchProducesFinding() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "concurrency.unchecked-sendable")
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.matchType == .clusterMatch)
        #expect(report.findings.first?.ruleId == "concurrency.unchecked-sendable")
        #expect(report.findings.first?.isRecurringInPulse == true)
    }

    @Test("Cluster match: non-recurring cluster produces non-recurring finding")
    func clusterMatchNonRecurring() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "safety.force-unwrap", isRecurring: false)
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "safety.force-unwrap")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.isRecurringInPulse == false)
    }

    @Test("Cluster match: passing result does not trigger finding")
    func clusterMatchPassingNoFinding() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "concurrency.unchecked-sendable")
        ])
        let metadata = makeMetadata(results: [makePassingResult()])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        #expect(report.findings.isEmpty)
    }

    @Test("Cluster match: unmatched ruleId produces no finding")
    func clusterMatchUnmatchedRuleId() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "safety.force-unwrap")
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        let clusterFindings = report.findings.filter { $0.matchType == .clusterMatch }
        #expect(clusterFindings.isEmpty)
    }

    // MARK: - Anomaly Pattern Matching

    @Test("Anomaly match: failed checker matching negative anomaly metric produces finding")
    func anomalyMatchProducesFinding() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(anomalies: [
            makeAnomaly(metric: "failuresByChecker.ConcurrencyAuditor", direction: .negative)
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(checkerId: "ConcurrencyAuditor")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        let anomalyFindings = report.findings.filter { $0.matchType == .anomalyPattern }
        #expect(anomalyFindings.count == 1)
        #expect(anomalyFindings.first?.checkerId == "ConcurrencyAuditor")
    }

    @Test("Anomaly match: positive anomaly does not trigger finding")
    func anomalyMatchPositiveNoFinding() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(anomalies: [
            makeAnomaly(metric: "failuresByChecker.ConcurrencyAuditor", direction: .positive)
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(checkerId: "ConcurrencyAuditor")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        let anomalyFindings = report.findings.filter { $0.matchType == .anomalyPattern }
        #expect(anomalyFindings.isEmpty)
    }

    // MARK: - Unaddressed Policy Matching

    @Test("Unaddressed policy: ruleId still failing that has a proposed policy produces finding")
    func unaddressedPolicyProducesFinding() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(
            proposedPolicyUpdates: ["concurrency.unchecked-sendable: Require justification comment"]
        )
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        let policyFindings = report.findings.filter { $0.matchType == .unaddressedPolicy }
        #expect(policyFindings.count == 1)
    }

    @Test("Unaddressed policy: no match when ruleId not in policy string")
    func unaddressedPolicyNoMatch() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(
            proposedPolicyUpdates: ["safety.force-unwrap: Ban force unwraps"]
        )
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        let policyFindings = report.findings.filter { $0.matchType == .unaddressedPolicy }
        #expect(policyFindings.isEmpty)
    }

    // MARK: - Exemptions

    @Test("Exemption suppresses specific matchType finding")
    func exemptionSuppressesMatchType() async throws {
        let writer = TelemetryWriter()
        let exemption = ConsistencyExemption(
            ruleId: "concurrency.unchecked-sendable",
            matchType: .clusterMatch,
            justification: "Legitimate C-interop usage",
            addedDate: makeDate("2026-04-01"),
            approvedBy: "jpurnell"
        )
        let auditor = PolicyDiscoveryAuditor(writer: writer, exemptions: [exemption])
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "concurrency.unchecked-sendable")
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        let clusterFindings = report.findings.filter { $0.matchType == .clusterMatch }
        #expect(clusterFindings.isEmpty)
    }

    @Test("Nil matchType exemption suppresses all match types for ruleId")
    func exemptionNilMatchTypeSuppressesAll() async throws {
        let writer = TelemetryWriter()
        let exemption = ConsistencyExemption(
            ruleId: "concurrency.unchecked-sendable",
            matchType: nil,
            justification: "Entirely exempt",
            addedDate: makeDate("2026-04-01"),
            approvedBy: "jpurnell"
        )
        let auditor = PolicyDiscoveryAuditor(writer: writer, exemptions: [exemption])
        let pulse = makePulse(
            violationClusters: [makeCluster(ruleId: "concurrency.unchecked-sendable")],
            proposedPolicyUpdates: ["concurrency.unchecked-sendable: Add justification"]
        )
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        #expect(report.findings.isEmpty)
    }

    @Test("Exemption for one matchType does not suppress other match types")
    func exemptionDoesNotSuppressOtherTypes() async throws {
        let writer = TelemetryWriter()
        let exemption = ConsistencyExemption(
            ruleId: "concurrency.unchecked-sendable",
            matchType: .clusterMatch,
            justification: "Only exempt from cluster matching",
            addedDate: makeDate("2026-04-01"),
            approvedBy: "jpurnell"
        )
        let auditor = PolicyDiscoveryAuditor(writer: writer, exemptions: [exemption])
        let pulse = makePulse(
            violationClusters: [makeCluster(ruleId: "concurrency.unchecked-sendable")],
            proposedPolicyUpdates: ["concurrency.unchecked-sendable: Add justification"]
        )
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        let clusterFindings = report.findings.filter { $0.matchType == .clusterMatch }
        let policyFindings = report.findings.filter { $0.matchType == .unaddressedPolicy }
        #expect(clusterFindings.isEmpty)
        #expect(policyFindings.count == 1)
    }

    // MARK: - Scoring Integration

    @Test("Report consistency score reflects findings")
    func reportScoreReflectsFindings() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "concurrency.unchecked-sendable", isRecurring: true)
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        #expect(report.consistencyScore < 1.0)
        #expect(report.consistencyScore > 0.0)
    }

    @Test("Empty findings produce score 1.0")
    func emptyFindingsScoreOne() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse()
        let metadata = makeMetadata(results: [makePassingResult()])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        #expect(abs(report.consistencyScore - 1.0) < 1e-6)
    }

    // MARK: - Multiple Finding Types

    @Test("Multiple match types from same gate run")
    func multipleMatchTypes() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(
            violationClusters: [makeCluster(ruleId: "concurrency.unchecked-sendable")],
            anomalies: [makeAnomaly(metric: "failuresByChecker.ConcurrencyAuditor", direction: .negative)],
            proposedPolicyUpdates: ["concurrency.unchecked-sendable: Require justification"]
        )
        let metadata = makeMetadata(results: [
            makeFailedResult(checkerId: "ConcurrencyAuditor", ruleId: "concurrency.unchecked-sendable")
        ])

        let report = await auditor.audit(metadata: metadata, against: pulse)
        let matchTypes = Set(report.findings.map(\.matchType))
        #expect(matchTypes.contains(.clusterMatch))
        #expect(matchTypes.contains(.anomalyPattern))
        #expect(matchTypes.contains(.unaddressedPolicy))
    }

    @Test("Report captures pulse week label")
    func reportCapturesPulseWeekLabel() async throws {
        let writer = TelemetryWriter()
        let auditor = PolicyDiscoveryAuditor(writer: writer)
        let pulse = makePulse(weekLabel: "2026-W17")
        let metadata = makeMetadata()

        let report = await auditor.audit(metadata: metadata, against: pulse)
        #expect(report.pulseWeekLabel == "2026-W17")
    }
}
