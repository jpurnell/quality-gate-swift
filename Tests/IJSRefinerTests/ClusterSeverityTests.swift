import Foundation
import IJSAggregator
import CorpusKit
import QualityGateTypes
import Testing
@testable import IJSRefiner

/// Tests that violation clusters are built from violations.
///
/// Cluster construction counted every diagnostic emitted by a failing checker, notes included.
/// A checker's *failure* was standing in for a diagnostic's *severity*, so a rule that only
/// ever emits notes could accumulate a cluster — and `doc-code.coverage` did, at 1,903
/// occurrences, from a diagnostic that is severity `note` in all 12,844 recorded cases and is
/// emitted precisely when the checker succeeds. Emitting it *is* the success path, so no edit
/// to any repository could drive that cluster to zero.
@Suite("Cluster construction counts violations only")
struct ClusterSeverityTests {

    private func metadata(
        projectID: String = "proj",
        diagnostics: [Diagnostic]
    ) -> CheckResultMetadata {
        CheckResultMetadata(
            projectID: projectID,
            timestamp: Date(timeIntervalSince1970: 1_755_000_000),
            environment: .local,
            decisionOwner: "test-owner",
            results: [CheckResult(
                checkerId: "doc-code",
                status: .failed,
                diagnostics: diagnostics,
                overrides: [],
                duration: .zero
            )],
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: 0.85
        )
    }

    private func diagnostic(_ severity: Diagnostic.Severity, _ ruleId: String) -> Diagnostic {
        Diagnostic(severity: severity, message: "m", ruleId: ruleId)
    }

    /// §10's reference truth, drawn from the corpus rather than invented: a rule recorded as
    /// `note` in every occurrence must build no cluster, however many times it appears.
    @Test("100 note-severity coverage diagnostics build no cluster")
    func notesBuildNoCluster() async {
        let refiner = PulseRefiner(writer: DirectCorpusTransport())
        let records = (0..<100).map { index in
            metadata(
                projectID: "proj-\(index % 3)",
                diagnostics: [diagnostic(.note, "doc-code.coverage")]
            )
        }

        let clusters = await refiner.detectClusters(
            from: records,
            calibrations: [],
            previousClusters: []
        )

        #expect(!clusters.contains { $0.ruleId == "doc-code.coverage" })
    }

    /// The other half of the assertion, and the one that must not move: error-severity counts
    /// are unchanged by the filter. `exact-double-equality` is `error` in all 1,857 recorded
    /// occurrences and its cluster survives intact.
    @Test("Error-severity diagnostics still build clusters, at the same count")
    func errorsStillCluster() async {
        let refiner = PulseRefiner(writer: DirectCorpusTransport())
        let records = (0..<12).map { index in
            metadata(
                projectID: "proj-\(index % 3)",
                diagnostics: [diagnostic(.error, "exact-double-equality")]
            )
        }

        let clusters = await refiner.detectClusters(
            from: records,
            calibrations: [],
            previousClusters: []
        )

        guard let cluster = clusters.first(where: { $0.ruleId == "exact-double-equality" }) else {
            Issue.record("expected an error-severity rule to cluster")
            return
        }
        #expect(cluster.occurrenceCount == 12)
    }

    /// Warnings are violations too — the filter is `>= .warning`, not `== .error`. A checker
    /// that fails on warnings alone must still cluster.
    @Test("Warning-severity diagnostics cluster")
    func warningsCluster() async {
        let refiner = PulseRefiner(writer: DirectCorpusTransport())
        let records = (0..<12).map { index in
            metadata(
                projectID: "proj-\(index % 3)",
                diagnostics: [diagnostic(.warning, "missing-assertion")]
            )
        }

        let clusters = await refiner.detectClusters(
            from: records,
            calibrations: [],
            previousClusters: []
        )

        #expect(clusters.contains { $0.ruleId == "missing-assertion" })
    }

    /// A single failing checker emits both kinds. Only the violation is counted — the note
    /// riding alongside it must not inherit the failure.
    @Test("A failing checker's notes do not inherit its failure")
    func mixedSeveritiesSplit() async {
        let refiner = PulseRefiner(writer: DirectCorpusTransport())
        let records = (0..<12).map { index in
            metadata(
                projectID: "proj-\(index % 3)",
                diagnostics: [
                    diagnostic(.error, "doc-code.compile-error"),
                    diagnostic(.note, "doc-code.coverage"),
                ]
            )
        }

        let clusters = await refiner.detectClusters(
            from: records,
            calibrations: [],
            previousClusters: []
        )

        #expect(clusters.contains { $0.ruleId == "doc-code.compile-error" })
        #expect(!clusters.contains { $0.ruleId == "doc-code.coverage" })
    }
}
