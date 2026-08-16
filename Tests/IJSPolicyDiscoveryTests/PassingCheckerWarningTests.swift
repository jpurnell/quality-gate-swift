import Testing
import Foundation
import QualityGateTypes
@testable import IJSPolicyDiscovery
import IJSSensor
import IJSAggregator

/// Tests that a violation counts as one wherever it was reported.
///
/// Counting used to require `status == .failed` **and** `isViolation`. Those are two different
/// tests, and the first one was wrong: a checker can pass while emitting warnings, and
/// `doc-lint` did exactly that in the run that prompted this work — passing, with two warnings.
/// Those warnings are violations by severity, but the status filter dropped the whole checker,
/// so they never reached scoring.
///
/// The effect was that score impact depended on whether a checker chose to *fail* or merely
/// *warn* — a decision each checker makes for its own reasons, unrelated to how serious the
/// finding is. A rule could be violated every run for weeks and never score, purely because
/// its checker reported warnings without failing.
///
/// Severity decides. Resolved 2026-08-15; §15's first open question.
@Suite("Violations count regardless of checker status")
struct PassingCheckerWarningTests {

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

    private func makePulse(ruleIds: [String]) -> InstitutionalPulse {
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
            violationClusters: ruleIds.map {
                ViolationCluster(
                    ruleId: $0,
                    occurrenceCount: 5,
                    affectedProjectCount: 1,
                    dominantRootCause: "systemic",
                    dominantFailedStep: .diagnosis,
                    isRecurring: true
                )
            },
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: makeDate("2026-04-28")
        )
    }

    /// The `doc-lint` case: passed, and emitted warnings while doing it.
    @Test("A warning inside a passing checker is a violation")
    func warningInPassingCheckerCounts() async {
        let auditor = PolicyDiscoveryAuditor(writer: DirectCorpusTransport())
        let metadata = makeMetadata(results: [CheckResult(
            checkerId: "doc-lint",
            status: .passed,
            diagnostics: [
                Diagnostic(severity: .warning, message: "m", ruleId: "doc-lint.ambiguous-link"),
            ],
            duration: .seconds(1)
        )])

        let report = await auditor.audit(
            metadata: metadata,
            against: makePulse(ruleIds: ["doc-lint.ambiguous-link"])
        )

        #expect(report.findings.count == 1)
        #expect(report.findings.first?.ruleId == "doc-lint.ambiguous-link")
    }

    /// An error inside a checker that somehow still passed is likewise a violation. Severity is
    /// the property being tested; the enclosing status is not consulted at all.
    @Test("An error inside a passing checker is a violation")
    func errorInPassingCheckerCounts() async {
        let auditor = PolicyDiscoveryAuditor(writer: DirectCorpusTransport())
        let metadata = makeMetadata(results: [CheckResult(
            checkerId: "doc-lint",
            status: .passed,
            diagnostics: [
                Diagnostic(severity: .error, message: "m", ruleId: "doc-lint.broken-symbol"),
            ],
            duration: .seconds(1)
        )])

        let report = await auditor.audit(
            metadata: metadata,
            against: makePulse(ruleIds: ["doc-lint.broken-symbol"])
        )

        #expect(report.findings.count == 1)
    }

    /// Widening to passing checkers must not drag notes in with it. This is the guard that
    /// keeps the two changes independent: the severity filter still applies, so a passing
    /// checker's coverage note is as silent as a failing checker's was.
    @Test("A note inside a passing checker is still not a violation")
    func noteInPassingCheckerIsSilent() async {
        let auditor = PolicyDiscoveryAuditor(writer: DirectCorpusTransport())
        let metadata = makeMetadata(results: [CheckResult(
            checkerId: "doc-code",
            status: .passed,
            diagnostics: [
                Diagnostic(severity: .note, message: "m", ruleId: "doc-code.coverage"),
            ],
            duration: .seconds(1)
        )])

        let report = await auditor.audit(
            metadata: metadata,
            against: makePulse(ruleIds: ["doc-code.coverage"])
        )

        #expect(report.findings.isEmpty)
    }

    /// A clean run is still clean. Widening what counts must not make a passing checker with
    /// nothing to say into a finding.
    @Test("A passing checker with no diagnostics produces nothing")
    func silentPassingCheckerProducesNothing() async {
        let auditor = PolicyDiscoveryAuditor(writer: DirectCorpusTransport())
        let metadata = makeMetadata(results: [CheckResult(
            checkerId: "safety",
            status: .passed,
            diagnostics: [],
            duration: .seconds(1)
        )])

        let report = await auditor.audit(
            metadata: metadata,
            against: makePulse(ruleIds: ["safety.force-unwrap"])
        )

        #expect(report.findings.isEmpty)
    }
}
