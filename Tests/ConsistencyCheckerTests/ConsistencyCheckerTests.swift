import Testing
import Foundation
@testable import ConsistencyChecker
import QualityGateCore
import CorpusKit
import IJSAggregator
import IJSPolicyDiscovery

@Suite("ConsistencyChecker")
struct ConsistencyCheckerTests {

    // MARK: - Helpers

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string) ?? Date(timeIntervalSince1970: 0)
    }

    private func makeConfig(
        corpusPath: String? = nil,
        projectID: String? = nil,
        consistencyThreshold: Double = 0.7,
        defaultRiskTier: Int = 2,
        scorerWeights: ScorerWeightsConfig? = nil,
        exemptions: [String] = []
    ) -> Configuration {
        Configuration(
            consistency: ConsistencyCheckerConfig(
                corpusPath: corpusPath,
                projectID: projectID,
                consistencyThreshold: consistencyThreshold,
                defaultRiskTier: defaultRiskTier,
                scorerWeights: scorerWeights,
                exemptions: exemptions
            )
        )
    }

    private func makeTempCorpus() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ijs-checker-test-\(UUID().uuidString)")
            .path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func makeMetadata(
        projectID: String = "test-project",
        results: [CheckResult] = [],
        timestamp: Date? = nil
    ) -> CheckResultMetadata {
        CheckResultMetadata(
            projectID: projectID,
            timestamp: timestamp ?? Date().addingTimeInterval(-86400),
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

    private func makePulse(
        weekLabel: String = "2026-W17",
        totalGateRuns: Int = 10,
        violationClusters: [ViolationCluster] = [],
        anomalies: [StatisticalAnomaly] = [],
        proposedPolicyUpdates: [String] = []
    ) -> InstitutionalPulse {
        let stats = PulseStatistics(
            totalGateRuns: totalGateRuns,
            passedRuns: totalGateRuns - 2,
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
        metric: String = "failuresByChecker.ConcurrencyAuditor",
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

    /// Sets up a temp corpus with a pulse and metadata, returns the corpus path.
    private func setupCorpusWithPulse(
        projectID: String = "test-project",
        pulse: InstitutionalPulse,
        metadata: CheckResultMetadata? = nil
    ) async throws -> String {
        let basePath = makeTempCorpus()
        let corpus = CorpusPath(basePath: basePath, projectID: projectID)
        let writer = TelemetryWriter()

        try await writer.writePulse(pulse, to: corpus)

        if let metadata {
            try await writer.write(metadata: metadata, calibrations: [], to: corpus)
        }

        return basePath
    }

    // MARK: - QualityChecker Conformance

    @Test("id is 'consistency'")
    func checkerId() {
        let checker = ConsistencyChecker()
        #expect(checker.id == "consistency")
    }

    @Test("name is 'Institutional Consistency'")
    func checkerName() {
        let checker = ConsistencyChecker()
        #expect(checker.name == "Institutional Consistency")
    }

    // MARK: - Unconfigured / Missing Corpus

    // Every outcome below is `.skipped`, never `.passed`. Each used to pass with a note
    // reading "consistency check skipped" — a status and a message that disagreed, where
    // the status is what the summary counts. Two repositories "passed" consistency for
    // three weeks against a directory that was not the corpus.

    @Test("Unconfigured corpus is skipped, not passed")
    func unconfiguredCorpus() async throws {
        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: nil)

        let result = try await checker.check(configuration: config)

        #expect(result.status == .skipped)
        #expect(result.checkerId == "consistency")
        #expect(result.diagnostics.map(\.ruleId) == ["consistency-unconfigured"])
        #expect(result.diagnostics.map(\.severity) == [.note])
        #expect(result.diagnostics.map(\.message) == [
            "Not checked: no `consistency.corpusPath` is configured. "
                + "Nothing was compared; this is not a pass.",
        ])
    }

    @Test("A corpus path that does not resolve to a directory is skipped and says so")
    func missingCorpusDirectory() async throws {
        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: "/nonexistent/path/to/corpus")

        let result = try await checker.check(configuration: config)

        #expect(result.status == .skipped)
        #expect(result.diagnostics.map(\.ruleId) == ["consistency-corpus-missing"])
        // A note, not a warning: on a CI runner the owner's absolute corpus path is absent
        // by design, and a warning there would fail `--strict` for every healthy project.
        #expect(result.diagnostics.map(\.severity) == [.note])
        #expect(result.diagnostics.map(\.message) == [
            "Not checked: corpus path '/nonexistent/path/to/corpus' does not resolve to a "
                + "directory. Nothing was compared; this is not a pass.",
        ])
    }

    @Test("A corpus path that is a file, not a directory, does not resolve")
    func corpusPathIsAFile() async throws {
        let basePath = makeTempCorpus()
        defer { cleanup(basePath) }
        try "not a corpus".write(toFile: basePath, atomically: true, encoding: .utf8)

        let result = try await ConsistencyChecker().check(
            configuration: makeConfig(corpusPath: basePath))

        #expect(result.status == .skipped)
        #expect(result.diagnostics.map(\.ruleId) == ["consistency-corpus-missing"])
    }

    @Test("A corpus path the gate refuses is skipped with a warning, and nothing is created")
    func rejectedCorpusPath() async throws {
        let projectRoot = URL(fileURLWithPath: makeTempCorpus(), isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { cleanup(projectRoot.path) }
        var config = makeConfig(corpusPath: "${ORG_JUDGEMENT_CORPUS:-}")
        config.projectRoot = projectRoot

        let result = try await ConsistencyChecker().check(configuration: config)

        #expect(result.status == .skipped)
        #expect(result.diagnostics.map(\.ruleId) == ["consistency-corpus-missing"])
        #expect(result.diagnostics.map(\.severity) == [.warning])
        #expect(result.diagnostics.map(\.message) == [
            "Not checked: " + ConfigPathProblem(
                key: "consistency.corpusPath",
                value: "${ORG_JUDGEMENT_CORPUS:-}",
                reason: .shellReference("${ORG_JUDGEMENT_CORPUS:-}")).message,
        ])
        #expect(try FileManager.default.contentsOfDirectory(atPath: projectRoot.path) == [])
    }

    @Test("The literal directory an earlier gate created is not mistaken for a corpus")
    func literalDirectoryFromAnEarlierRunIsNotACorpus() async throws {
        // The state the two affected repositories were actually in: the directory exists,
        // because an earlier binary created it. Its existence is what turned "corpus
        // missing" into "no pulse" and let the skip read as a pass.
        let projectRoot = URL(fileURLWithPath: makeTempCorpus(), isDirectory: true)
        let stray = projectRoot.appendingPathComponent("${ORG_JUDGEMENT_CORPUS:-}/telemetry/demo")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        defer { cleanup(projectRoot.path) }
        var config = makeConfig(corpusPath: "${ORG_JUDGEMENT_CORPUS:-}", projectID: "demo")
        config.projectRoot = projectRoot

        let result = try await ConsistencyChecker().check(configuration: config)

        #expect(result.status == .skipped)
        #expect(result.diagnostics.map(\.severity) == [.warning])
        #expect(result.diagnostics.map(\.ruleId) == ["consistency-corpus-missing"])
    }

    // MARK: - No Pulse

    @Test("A corpus with no pulse is skipped, not passed")
    func noPulseInCorpus() async throws {
        let basePath = makeTempCorpus()
        defer { cleanup(basePath) }
        try FileManager.default.createDirectory(atPath: basePath, withIntermediateDirectories: true)

        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: basePath, projectID: "test-project")

        let result = try await checker.check(configuration: config)

        let resolved = URL(fileURLWithPath: basePath).standardizedFileURL.path
        #expect(result.status == .skipped)
        #expect(result.diagnostics.map(\.ruleId) == ["consistency-no-pulse"])
        #expect(result.diagnostics.map(\.severity) == [.note])
        #expect(result.diagnostics.map(\.message) == [
            "Not checked: the corpus at '\(resolved)' holds no institutional pulse. "
                + "Nothing was compared; this is not a pass.",
        ])
    }

    // MARK: - Pulse With Findings

    @Test("Pulse with matching cluster produces finding diagnostics")
    func pulseWithClusterFindings() async throws {
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "concurrency.unchecked-sendable")
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])
        let basePath = try await setupCorpusWithPulse(
            pulse: pulse,
            metadata: metadata
        )
        defer { cleanup(basePath) }

        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: basePath, projectID: "test-project")

        let result = try await checker.check(configuration: config)

        let findingDiagnostics = result.diagnostics.filter {
            $0.ruleId?.hasPrefix("consistency-finding") ?? false
        }
        #expect(!findingDiagnostics.isEmpty)
    }

    @Test("Score below threshold returns warning status")
    func scoreBelowThreshold() async throws {
        let pulse = makePulse(
            violationClusters: [
                makeCluster(ruleId: "concurrency.unchecked-sendable", isRecurring: true),
                makeCluster(ruleId: "safety.force-unwrap", occurrenceCount: 8, isRecurring: true),
            ],
            anomalies: [
                makeAnomaly(metric: "failuresByChecker.ConcurrencyAuditor"),
            ],
            proposedPolicyUpdates: [
                "concurrency.unchecked-sendable: Require justification",
                "safety.force-unwrap: Ban in new code",
            ]
        )
        let metadata = makeMetadata(results: [
            makeFailedResult(checkerId: "ConcurrencyAuditor", ruleId: "concurrency.unchecked-sendable"),
            makeFailedResult(checkerId: "SafetyAuditor", ruleId: "safety.force-unwrap"),
        ])
        let basePath = try await setupCorpusWithPulse(pulse: pulse, metadata: metadata)
        defer { cleanup(basePath) }

        let checker = ConsistencyChecker()
        let config = makeConfig(
            corpusPath: basePath,
            projectID: "test-project",
            consistencyThreshold: 0.9
        )

        let result = try await checker.check(configuration: config)

        #expect(result.status == .warning)
        // The WARNING status is backed by a warning the summary can count. Without it a
        // below-threshold run whose findings were all notes failed --strict while printing
        // `0 warning(s)`, and the gate had to say so on the checker's behalf.
        let belowThreshold = result.diagnostics.filter { $0.ruleId == "consistency-below-threshold" }
        #expect(belowThreshold.count == 1)
        #expect(belowThreshold.first?.severity == .warning)
        #expect(belowThreshold.first?.message.contains("below the threshold 0.90") == true)
        #expect(!result.reconciled().diagnostics.contains { $0.ruleId == "gate.status-without-finding" })
        // Telemetry parses the score out of this note's message; it is left as it was.
        #expect(result.diagnostics.filter { $0.ruleId == "consistency-score" }.map(\.severity) == [.note])
    }

    @Test("Score above threshold returns passed status")
    func scoreAboveThreshold() async throws {
        let pulse = makePulse()
        let metadata = makeMetadata(results: [
            CheckResult(
                checkerId: "SafetyAuditor",
                status: .passed,
                diagnostics: [],
                duration: .seconds(1)
            )
        ])
        let basePath = try await setupCorpusWithPulse(pulse: pulse, metadata: metadata)
        defer { cleanup(basePath) }

        let checker = ConsistencyChecker()
        let config = makeConfig(
            corpusPath: basePath,
            projectID: "test-project",
            consistencyThreshold: 0.7
        )

        let result = try await checker.check(configuration: config)

        #expect(result.status == .passed)
        #expect(!result.diagnostics.contains { $0.ruleId == "consistency-below-threshold" })
    }

    // MARK: - No Metadata (Pulse-Only)

    @Test("Pulse exists but no metadata is skipped, not passed")
    func pulseWithoutMetadata() async throws {
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "concurrency.unchecked-sendable")
        ])
        let basePath = try await setupCorpusWithPulse(pulse: pulse, metadata: nil)
        defer { cleanup(basePath) }

        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: basePath, projectID: "test-project")

        let result = try await checker.check(configuration: config)

        #expect(result.status == .skipped)
        #expect(result.diagnostics.map(\.ruleId) == ["consistency-no-metadata"])
        #expect(result.diagnostics.map(\.severity) == [.note])
    }

    // MARK: - Consistency Score in Diagnostics

    @Test("Consistency score is reported in diagnostics")
    func consistencyScoreReported() async throws {
        let pulse = makePulse(violationClusters: [
            makeCluster(ruleId: "concurrency.unchecked-sendable", isRecurring: true)
        ])
        let metadata = makeMetadata(results: [
            makeFailedResult(ruleId: "concurrency.unchecked-sendable")
        ])
        let basePath = try await setupCorpusWithPulse(pulse: pulse, metadata: metadata)
        defer { cleanup(basePath) }

        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: basePath, projectID: "test-project")

        let result = try await checker.check(configuration: config)

        let scoreDiag = result.diagnostics.first { $0.ruleId == "consistency-score" }
        #expect(scoreDiag?.ruleId == "consistency-score")
        #expect(scoreDiag?.message.contains("Institutional consistency score") ?? false)
    }

    // MARK: - Calibration-Recommended Diagnostics

    private func makeCalibration(
        ruleId: String,
        rootCause: String,
        date: Date
    ) -> JudgmentCalibration {
        JudgmentCalibration(
            date: date,
            decisionOwner: "jpurnell",
            practitioner: "agent",
            riskTier: .operational,
            rootCauseAnalysis: RootCauseAnalysis(
                proximateCause: "Override of \(ruleId): test override",
                chainOfInquiry: ["Why?"],
                rootCause: rootCause,
                failedStep: .diagnosis,
                isRecurringPattern: false
            ),
            redTeamDissent: "none",
            proposedPolicyUpdate: nil,
            pulseContribution: "test"
        )
    }

    private func makeSafetyResult() -> CheckResult {
        CheckResult(
            checkerId: "safety",
            status: .passed,
            diagnostics: [],
            duration: .seconds(1)
        )
    }

    @Test("Checker at validity with high FP rate produces calibration-recommended note")
    func highFalsePositiveRateProducesCalibrationNote() async throws {
        let pulse = makePulse()
        let basePath = makeTempCorpus()
        defer { cleanup(basePath) }

        let corpus = CorpusPath(basePath: basePath, projectID: "test-project")
        let writer = TelemetryWriter()

        try await writer.writePulse(pulse, to: corpus)

        let now = Date()
        for dayOffset in 0..<31 {
            let timestamp = now.addingTimeInterval(-Double(dayOffset) * 86400 - Double(dayOffset))
            let metadata = makeMetadata(
                results: [makeSafetyResult()],
                timestamp: timestamp
            )
            let calibrations: [JudgmentCalibration]
            if dayOffset < 20 {
                calibrations = [makeCalibration(
                    ruleId: "safety.force-unwrap",
                    rootCause: "imprecise",
                    date: timestamp
                )]
            } else if dayOffset < 25 {
                calibrations = [makeCalibration(
                    ruleId: "safety.force-unwrap",
                    rootCause: "structural",
                    date: timestamp
                )]
            } else {
                calibrations = []
            }
            try await writer.write(metadata: metadata, calibrations: calibrations, to: corpus)
        }

        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: basePath, projectID: "test-project")

        let result = try await checker.check(configuration: config)

        let calDiags = result.diagnostics.filter { $0.ruleId == "calibration-recommended" }
        // `#expect(!isEmpty)` followed by `guard let … else { return }` did assert — the
        // expectation fails before the guard exits — but it says the same thing twice and
        // the guard reads as a silent escape. `#require` says it once and stops the test at
        // the point the assumption breaks.
        let diag = try #require(calDiags.first)
        #expect(diag.severity == .note)
        #expect(diag.message.contains("safety"))
        #expect(diag.message.contains("false positive rate"))
    }

    @Test("Checker at validity with low FP rate produces no calibration-recommended note")
    func lowFalsePositiveRateNoCalibrationNote() async throws {
        let pulse = makePulse()
        let basePath = makeTempCorpus()
        defer { cleanup(basePath) }

        let corpus = CorpusPath(basePath: basePath, projectID: "test-project")
        let writer = TelemetryWriter()

        try await writer.writePulse(pulse, to: corpus)

        let now = Date()
        for dayOffset in 0..<31 {
            let timestamp = now.addingTimeInterval(-Double(dayOffset) * 86400 - Double(dayOffset))
            let metadata = makeMetadata(
                results: [makeSafetyResult()],
                timestamp: timestamp
            )
            let calibrations: [JudgmentCalibration]
            if dayOffset < 5 {
                calibrations = [makeCalibration(
                    ruleId: "safety.force-unwrap",
                    rootCause: "imprecise",
                    date: timestamp
                )]
            } else if dayOffset < 20 {
                calibrations = [makeCalibration(
                    ruleId: "safety.force-unwrap",
                    rootCause: "structural",
                    date: timestamp
                )]
            } else {
                calibrations = []
            }
            try await writer.write(metadata: metadata, calibrations: calibrations, to: corpus)
        }

        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: basePath, projectID: "test-project")

        let result = try await checker.check(configuration: config)

        let calDiags = result.diagnostics.filter { $0.ruleId == "calibration-recommended" }
        #expect(calDiags.isEmpty)
    }

    @Test("Checker below validity threshold produces no calibration-recommended note")
    func belowValidityThresholdNoCalibrationNote() async throws {
        let pulse = makePulse()
        let basePath = makeTempCorpus()
        defer { cleanup(basePath) }

        let corpus = CorpusPath(basePath: basePath, projectID: "test-project")
        let writer = TelemetryWriter()

        try await writer.writePulse(pulse, to: corpus)

        let now = Date()
        for dayOffset in 0..<20 {
            let timestamp = now.addingTimeInterval(-Double(dayOffset) * 86400 - Double(dayOffset))
            let metadata = makeMetadata(
                results: [makeSafetyResult()],
                timestamp: timestamp
            )
            let calibrations = [makeCalibration(
                ruleId: "safety.force-unwrap",
                rootCause: "imprecise",
                date: timestamp
            )]
            try await writer.write(metadata: metadata, calibrations: calibrations, to: corpus)
        }

        let checker = ConsistencyChecker()
        let config = makeConfig(corpusPath: basePath, projectID: "test-project")

        let result = try await checker.check(configuration: config)

        let calDiags = result.diagnostics.filter { $0.ruleId == "calibration-recommended" }
        #expect(calDiags.isEmpty)
    }
}
