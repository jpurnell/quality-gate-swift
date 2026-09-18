import Foundation
import IJSAggregator
import CorpusKit
import QualityGateTypes
import Testing
@testable import IJSRefiner

/// Tests that `consistency`'s own findings are not counted as violations.
///
/// A `consistency-finding.*` diagnostic reports *on* violations; it is not a violation of
/// anything in the code. Counting it is the same category error as counting coverage notes,
/// one level up — and it was invisible until warnings from passing checkers started counting,
/// because `consistency` reports `passed` or `warning` and never `failed`.
///
/// Left uncounted-for, `consistency-finding.clusterMatch` accumulated 322 occurrences in a
/// single pulse. It inflates monotonically: every run's telemetry carries the finding, so
/// every pulse counts it again, and nothing ever drives it down. In the isolation path
/// (`--check consistency`), which audits persisted telemetry rather than the current run, it
/// can also match its own earlier finding and produce a new one.
@Suite("Consistency findings are not violations")
struct ConsistencySelfReferenceTests {

    private func metadata(results: [CheckResult], projectID: String) -> CheckResultMetadata {
        CheckResultMetadata(
            projectID: projectID,
            timestamp: Date(timeIntervalSince1970: 1_755_000_000),
            environment: .local,
            decisionOwner: "test-owner",
            results: results,
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: 0.75
        )
    }

    /// The exact shape observed in the corpus: `consistency`, not failed, emitting a
    /// warning-severity finding about a cluster.
    private func consistencyResult() -> CheckResult {
        CheckResult(
            checkerId: "consistency",
            status: .warning,
            diagnostics: [
                Diagnostic(
                    severity: .warning,
                    message: "Rule 'docc' matched ViolationCluster with 24 occurrences",
                    ruleId: "consistency-finding.clusterMatch"
                ),
                Diagnostic(
                    severity: .note,
                    message: "Institutional consistency score: 0.75",
                    ruleId: "consistency-score"
                ),
            ],
            duration: .zero
        )
    }

    @Test("A consistency finding does not build a cluster")
    func consistencyFindingsDoNotCluster() async {
        let refiner = PulseRefiner(writer: DirectCorpusTransport())
        let records = (0..<20).map { metadata(results: [consistencyResult()], projectID: "proj-\($0 % 3)") }

        let clusters = await refiner.detectClusters(
            from: records,
            calibrations: [],
            previousClusters: []
        )

        #expect(!clusters.contains { $0.ruleId == "consistency-finding.clusterMatch" })
    }

    /// The guard that keeps the fix narrow: excluding the auditor's own output must not
    /// exclude anybody else's. A warning from an ordinary passing checker still counts, which
    /// is the whole point of the change that exposed this.
    @Test("Other checkers' warnings still cluster")
    func otherCheckersStillCluster() async {
        let refiner = PulseRefiner(writer: DirectCorpusTransport())
        let docLint = CheckResult(
            checkerId: "doc-lint",
            status: .passed,
            diagnostics: [Diagnostic(severity: .warning, message: "m", ruleId: "docc")],
            duration: .zero
        )
        let records = (0..<20).map {
            metadata(results: [docLint, consistencyResult()], projectID: "proj-\($0 % 3)")
        }

        let clusters = await refiner.detectClusters(
            from: records,
            calibrations: [],
            previousClusters: []
        )

        #expect(clusters.contains { $0.ruleId == "docc" })
        #expect(!clusters.contains { $0.ruleId == "consistency-finding.clusterMatch" })
    }
}
