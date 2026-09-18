import Testing
import Foundation
@testable import ConsistencyChecker
import QualityGateCore
import CorpusKit
import IJSAggregator
import IJSPolicyDiscovery

/// Tests that `consistency` audits the run it is printed inside of.
///
/// It read the newest telemetry on disk, and the current run's telemetry is written *after*
/// every checker completes — so "newest" was always the run before. A clean run reported the
/// findings of the run that preceded it, and the advice a user had to be given was "run the
/// gate again and believe the second answer", which is indistinguishable from telling them to
/// ignore the checker.
///
/// Reproduced in this repository on 2026-08-15: run 1 failed two checkers, run 2 was clean and
/// warned about both of them, run 3 on an identical tree was clean. The clusters mapped
/// one-to-one onto the checkers that had failed the *previous* run.
@Suite("ConsistencyChecker provenance")
struct ConsistencyProvenanceTests {

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string) ?? Date(timeIntervalSince1970: 0)
    }

    private func makeConfig(corpusPath: String?) -> Configuration {
        Configuration(
            consistency: ConsistencyCheckerConfig(
                corpusPath: corpusPath,
                projectID: "test-project",
                consistencyThreshold: 0.7,
                defaultRiskTier: 2,
                scorerWeights: nil,
                exemptions: []
            )
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

    /// Corpus fixture, inlined rather than shared: `ConsistencyCheckerTests`' helpers are
    /// private to that suite, and widening them to share four lines would couple two suites
    /// that are otherwise independent.
    private func setupCorpus(
        pulse: InstitutionalPulse,
        priorResults: [CheckResult]
    ) async throws -> String {
        let basePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ijs-provenance-\(UUID().uuidString)")
            .path
        let corpus = CorpusPath(basePath: basePath, projectID: "test-project")
        let writer = TelemetryWriter()
        try await writer.writePulse(pulse, to: corpus)
        try await writer.write(
            metadata: CheckResultMetadata(
                projectID: "test-project",
                timestamp: Date().addingTimeInterval(-86_400),
                environment: .local,
                decisionOwner: "jpurnell",
                results: priorResults,
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            ),
            calibrations: [],
            to: corpus
        )
        return basePath
    }

    private func failedResult(ruleId: String) -> CheckResult {
        CheckResult(
            checkerId: "ConcurrencyAuditor",
            status: .failed,
            diagnostics: [Diagnostic(severity: .error, message: "m", ruleId: ruleId)],
            duration: .seconds(1)
        )
    }

    private func passingResult() -> CheckResult {
        CheckResult(
            checkerId: "ConcurrencyAuditor",
            status: .passed,
            diagnostics: [],
            duration: .seconds(1)
        )
    }

    /// **The regression test whose absence let this ship.** A previous run failed and is on
    /// disk; this run is clean. Auditing the current run must find nothing.
    @Test("A clean run after a failing run reports no findings")
    func cleanRunAfterFailureIsClean() async throws {
        let basePath = try await setupCorpus(
            pulse: makePulse(violationClusters: [
                makeCluster(ruleId: "concurrency.unchecked-sendable")
            ]),
            priorResults: [failedResult(ruleId: "concurrency.unchecked-sendable")]
        )
        defer { try? FileManager.default.removeItem(atPath: basePath) }

        let checker = ConsistencyChecker()
        let result = try await checker.audit(
            results: [passingResult()],
            configuration: makeConfig(corpusPath: basePath)
        )

        let findings = result.diagnostics.filter {
            $0.ruleId?.hasPrefix("consistency-finding") ?? false
        }
        #expect(findings.isEmpty)
    }

    /// The converse, so the fix cannot be "return nothing". A run that *is* violating a
    /// clustered rule right now must still be reported.
    @Test("A run that violates a clustered rule now is still reported")
    func currentViolationIsStillReported() async throws {
        let basePath = try await setupCorpus(
            pulse: makePulse(violationClusters: [
                makeCluster(ruleId: "concurrency.unchecked-sendable")
            ]),
            priorResults: [passingResult()]
        )
        defer { try? FileManager.default.removeItem(atPath: basePath) }

        let checker = ConsistencyChecker()
        let result = try await checker.audit(
            results: [failedResult(ruleId: "concurrency.unchecked-sendable")],
            configuration: makeConfig(corpusPath: basePath)
        )

        let findings = result.diagnostics.filter {
            $0.ruleId?.hasPrefix("consistency-finding") ?? false
        }
        #expect(!findings.isEmpty)
    }

    /// `--check consistency` in isolation has no current run to audit. The lag becomes
    /// legitimate rather than accidental there — provided the message says which run it read.
    @Test("check() alone labels the run it audited")
    func fallbackLabelsThePreviousRun() async throws {
        let basePath = try await setupCorpus(
            pulse: makePulse(violationClusters: [
                makeCluster(ruleId: "concurrency.unchecked-sendable")
            ]),
            priorResults: [failedResult(ruleId: "concurrency.unchecked-sendable")]
        )
        defer { try? FileManager.default.removeItem(atPath: basePath) }

        let checker = ConsistencyChecker()
        let result = try await checker.check(configuration: makeConfig(corpusPath: basePath))

        let provenanceNotes = result.diagnostics.filter {
            $0.ruleId == "consistency-audited-run"
        }
        #expect(provenanceNotes.count == 1)
        #expect(provenanceNotes.first?.message.contains("previous run") ?? false)
    }

    /// The post-run audit states that it audited *this* run, so a reader never has to wonder
    /// which run a score describes.
    @Test("audit() states that it audited the current run")
    func postRunAuditLabelsItself() async throws {
        let basePath = try await setupCorpus(
            pulse: makePulse(violationClusters: []),
            priorResults: [passingResult()]
        )
        defer { try? FileManager.default.removeItem(atPath: basePath) }

        let checker = ConsistencyChecker()
        let result = try await checker.audit(
            results: [passingResult()],
            configuration: makeConfig(corpusPath: basePath)
        )

        let provenanceNotes = result.diagnostics.filter {
            $0.ruleId == "consistency-audited-run"
        }
        #expect(provenanceNotes.count == 1)
        #expect(provenanceNotes.first?.message.contains("current run") ?? false)
    }
}
