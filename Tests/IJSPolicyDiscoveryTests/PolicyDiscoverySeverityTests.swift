import Testing
import Foundation
import QualityGateTypes
@testable import IJSPolicyDiscovery
import IJSSensor
import IJSAggregator

/// Tests that a consistency finding requires a *violation*, not merely a diagnostic emitted by
/// a checker that happened to fail.
///
/// `extractFailedRuleIds` collected every `ruleId` from a failing checker's diagnostics with no
/// severity test at all. A checker that fails on one error while also printing its coverage
/// note therefore reported both rules as violated — and the coverage note is the line the
/// checker prints when it *succeeds*.
@Suite("PolicyDiscoveryAuditor severity filtering")
struct PolicyDiscoverySeverityTests {

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string) ?? Date(timeIntervalSince1970: 0)
    }

    private func makeMetadata(results: [CheckResult]) -> CheckResultMetadata {
        CheckResultMetadata(
            projectID: "test-project",
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

    private func makeCluster(ruleId: String) -> ViolationCluster {
        ViolationCluster(
            ruleId: ruleId,
            occurrenceCount: 5,
            affectedProjectCount: 1,
            dominantRootCause: "systemic",
            dominantFailedStep: .diagnosis,
            isRecurring: true
        )
    }

    private func makePulse(violationClusters: [ViolationCluster]) -> InstitutionalPulse {
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
            anomalies: [],
            corpusSnapshots: [],
            projectSnapshots: [:]
        )
        return InstitutionalPulse(
            windowStart: makeDate("2026-04-21"),
            windowEnd: makeDate("2026-04-28"),
            weekLabel: "2026-W17",
            projects: ["test-project"],
            statistics: stats,
            violationClusters: violationClusters,
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: makeDate("2026-04-28")
        )
    }

    /// §10's first case. Both rules have clusters; only the error is a violation.
    @Test("A failing checker's note does not become a finding alongside its error")
    func noteAlongsideErrorYieldsOneFinding() async {
        let auditor = PolicyDiscoveryAuditor(writer: DirectCorpusTransport())
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "doc-code.compile-error"),
            makeCluster(ruleId: "doc-code.coverage"),
        ])
        let metadata = makeMetadata(results: [CheckResult(
            checkerId: "doc-code",
            status: .failed,
            diagnostics: [
                Diagnostic(severity: .error, message: "m", ruleId: "doc-code.compile-error"),
                Diagnostic(severity: .note, message: "m", ruleId: "doc-code.coverage"),
            ],
            duration: .seconds(1)
        )])

        let report = await auditor.audit(metadata: metadata, against: pulse)

        #expect(report.findings.count == 1)
        #expect(report.findings.first?.ruleId == "doc-code.compile-error")
    }

    /// §10's second case: a checker that *passed* while emitting coverage notes produces
    /// nothing, whatever the pulse says about those rules.
    @Test("Coverage notes on a passing checker produce no findings")
    func coverageNotesOnPassingCheckerAreSilent() async {
        let auditor = PolicyDiscoveryAuditor(writer: DirectCorpusTransport())
        let pulse = makePulse(violationClusters: [makeCluster(ruleId: "doc-code.coverage")])
        let metadata = makeMetadata(results: [CheckResult(
            checkerId: "doc-code",
            status: .passed,
            diagnostics: [
                Diagnostic(severity: .note, message: "m", ruleId: "doc-code.coverage"),
                Diagnostic(severity: .note, message: "m", ruleId: "doc-code.coverage"),
            ],
            duration: .seconds(1)
        )])

        let report = await auditor.audit(metadata: metadata, against: pulse)

        #expect(report.findings.isEmpty)
    }

    /// A checker failing with notes *only* — no violation anywhere — must produce nothing.
    /// This is the shape that made a clean run report warnings.
    @Test("A checker whose only diagnostics are notes produces no findings")
    func notesOnlyFailureIsSilent() async {
        let auditor = PolicyDiscoveryAuditor(writer: DirectCorpusTransport())
        let pulse = makePulse(violationClusters: [makeCluster(ruleId: "doc-code.coverage")])
        let metadata = makeMetadata(results: [CheckResult(
            checkerId: "doc-code",
            status: .failed,
            diagnostics: [
                Diagnostic(severity: .note, message: "m", ruleId: "doc-code.coverage"),
            ],
            duration: .seconds(1)
        )])

        let report = await auditor.audit(metadata: metadata, against: pulse)

        #expect(report.findings.isEmpty)
    }

    /// Warnings are violations. The filter is `>= .warning`, and narrowing it to errors alone
    /// would silently drop every warning-severity rule from consistency scoring.
    @Test("A warning is still a violation")
    func warningIsStillAViolation() async {
        let auditor = PolicyDiscoveryAuditor(writer: DirectCorpusTransport())
        let pulse = makePulse(violationClusters: [makeCluster(ruleId: "missing-assertion")])
        let metadata = makeMetadata(results: [CheckResult(
            checkerId: "test-quality",
            status: .failed,
            diagnostics: [
                Diagnostic(severity: .warning, message: "m", ruleId: "missing-assertion"),
            ],
            duration: .seconds(1)
        )])

        let report = await auditor.audit(metadata: metadata, against: pulse)

        #expect(report.findings.count == 1)
        #expect(report.findings.first?.ruleId == "missing-assertion")
    }
}
