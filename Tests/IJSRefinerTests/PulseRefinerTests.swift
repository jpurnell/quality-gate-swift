import Testing
import Foundation
import QualityGateTypes
@testable import IJSRefiner
import IJSSensor
import IJSAggregator

@Suite("PulseRefiner")
struct PulseRefinerTests {

    private let writer = TelemetryWriter()

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeDayDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeMetadata(
        projectID: String = "test-project",
        timestamp: Date,
        passed: Bool = true,
        overrideCount: Int = 0,
        failedCheckerIds: [String] = []
    ) -> CheckResultMetadata {
        var results: [CheckResult] = []
        if passed && failedCheckerIds.isEmpty {
            results.append(CheckResult(
                checkerId: "SafetyAuditor",
                status: .passed,
                diagnostics: [],
                overrides: [],
                duration: .zero
            ))
        }
        for checkerId in failedCheckerIds {
            results.append(CheckResult(
                checkerId: checkerId,
                status: .failed,
                diagnostics: [Diagnostic(
                    severity: .error,
                    message: "Test failure",
                    filePath: "Test.swift",
                    lineNumber: 1,
                    columnNumber: nil,
                    ruleId: "\(checkerId.lowercased()).test-rule"
                )],
                overrides: [],
                duration: .zero
            ))
        }

        var overrides: [OverrideRecord] = []
        for i in 0..<overrideCount {
            overrides.append(OverrideRecord(
                diagnosticOverride: DiagnosticOverride(
                    ruleId: "test.rule-\(i)",
                    justification: "Test justification",
                    filePath: "Test.swift",
                    lineNumber: 1
                ),
                author: "test-author",
                riskTier: .operational,
                authorityLevel: .peer
            ))
        }

        return CheckResultMetadata(
            projectID: projectID,
            timestamp: timestamp,
            environment: .local,
            decisionOwner: "test-owner",
            results: results,
            overrides: overrides,
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: 0.85
        )
    }

    private func makeCalibration(
        date: Date,
        rootCause: String = "contextually naive",
        failedStep: FiveStepStage = .diagnosis,
        proposedPolicy: String? = nil,
        ruleId: String = "concurrency.test-rule"
    ) -> JudgmentCalibration {
        JudgmentCalibration(
            date: date,
            decisionOwner: "test-owner",
            practitioner: "test-practitioner",
            riskTier: .safety,
            rootCauseAnalysis: RootCauseAnalysis(
                proximateCause: "Test proximate cause for \(ruleId)",
                chainOfInquiry: ["Why 1", "Why 2"],
                rootCause: rootCause,
                failedStep: failedStep,
                isRecurringPattern: false
            ),
            redTeamDissent: "Test dissent",
            proposedPolicyUpdate: proposedPolicy,
            pulseContribution: "Test contribution"
        )
    }

    // MARK: - buildSnapshots

    @Test("buildSnapshots: 3 records on 2 dates produces 2 snapshots")
    func buildSnapshots() async {
        let refiner = PulseRefiner(writer: writer)
        let metadata = [
            makeMetadata(timestamp: makeDate("2026-04-27T10:00:00"), passed: true),
            makeMetadata(timestamp: makeDate("2026-04-27T14:00:00"), passed: false, failedCheckerIds: ["SafetyAuditor"]),
            makeMetadata(timestamp: makeDate("2026-04-28T09:00:00"), passed: true, overrideCount: 1),
        ]
        let snapshots = await refiner.buildSnapshots(from: metadata, scope: "test-project")
        #expect(snapshots.count == 2)
        let day27 = snapshots.first { $0.date == makeDayDate("2026-04-27") }
        let day28 = snapshots.first { $0.date == makeDayDate("2026-04-28") }
        #expect(day27?.gateRuns == 2)
        #expect(day27?.passedRuns == 1)
        #expect(day27?.failedRuns == 1)
        #expect(day28?.gateRuns == 1)
        #expect(day28?.overrides == 1)
    }

    // MARK: - analyzeTrends

    @Test("analyzeTrends: 30 known values produce valid trends")
    func analyzeTrendsValid() async {
        let refiner = PulseRefiner(writer: writer)
        let snapshots: [DailySnapshot] = (0..<30).map { i in
            DailySnapshot(
                date: makeDayDate("2026-04-\(String(format: "%02d", (i % 28) + 1))"),
                scope: "test",
                gateRuns: 10, passedRuns: 8, failedRuns: 2,
                overrides: 1, calibrations: 0,
                failuresByChecker: [:], overridesByRiskTier: [:]
            )
        }
        let trends = await refiner.analyzeTrends(from: snapshots)
        #expect(!trends.isEmpty)
        let passRateTrend = trends.first { $0.metric == "passRate" }
        #expect(passRateTrend?.validity == .valid)
        #expect(passRateTrend?.sampleSize == 30)
    }

    @Test("analyzeTrends: 10 values produce preliminary trends")
    func analyzeTrendsPreliminary() async {
        let refiner = PulseRefiner(writer: writer)
        let snapshots: [DailySnapshot] = (0..<10).map { i in
            DailySnapshot(
                date: makeDayDate("2026-04-\(String(format: "%02d", i + 1))"),
                scope: "test",
                gateRuns: 10, passedRuns: 9, failedRuns: 1,
                overrides: 0, calibrations: 0,
                failuresByChecker: [:], overridesByRiskTier: [:]
            )
        }
        let trends = await refiner.analyzeTrends(from: snapshots)
        let passRateTrend = trends.first { $0.metric == "passRate" }
        #expect(passRateTrend?.validity == .preliminary)
    }

    // MARK: - detectAnomalies

    @Test("detectAnomalies: outlier in 30-day baseline flagged")
    func detectAnomaliesOutlier() async {
        let refiner = PulseRefiner(writer: writer)
        let baselineValues: [Double] = [0.09, 0.10, 0.08, 0.11, 0.10, 0.09, 0.12, 0.08, 0.10, 0.11,
                                        0.09, 0.10, 0.08, 0.11, 0.10, 0.09, 0.12, 0.08, 0.10, 0.11,
                                        0.09, 0.10, 0.08, 0.11, 0.10, 0.09, 0.12, 0.08, 0.10, 0.11]
        let baselineTrend = TrendAnalysis.compute(metric: "overrideRate", values: baselineValues)!

        let outlierSnapshot = DailySnapshot(
            date: makeDayDate("2026-04-28"),
            scope: "test",
            gateRuns: 10, passedRuns: 7, failedRuns: 3,
            overrides: 5, calibrations: 0,
            failuresByChecker: [:], overridesByRiskTier: [:]
        )
        let anomalies = await refiner.detectAnomalies(
            windowSnapshots: [outlierSnapshot],
            baselineTrends: [baselineTrend]
        )
        let overrideAnomaly = anomalies.first { $0.metric == "overrideRate" }
        #expect(overrideAnomaly?.metric == "overrideRate")
        #expect(overrideAnomaly?.direction == .negative)
        #expect(overrideAnomaly?.baselineValidity == .valid)
    }

    @Test("detectAnomalies: positive anomaly (exceptional pass rate)")
    func detectAnomaliesPositive() async {
        let refiner = PulseRefiner(writer: writer)
        let baselineValues: [Double] = [0.67, 0.72, 0.68, 0.74, 0.66, 0.71, 0.73, 0.69, 0.70, 0.65,
                                        0.72, 0.68, 0.74, 0.67, 0.71, 0.73, 0.69, 0.70, 0.66, 0.75,
                                        0.67, 0.72, 0.68, 0.74, 0.66, 0.71, 0.73, 0.69, 0.70, 0.65]
        let baselineTrend = TrendAnalysis.compute(metric: "passRate", values: baselineValues)!

        let goodSnapshot = DailySnapshot(
            date: makeDayDate("2026-04-28"),
            scope: "test",
            gateRuns: 10, passedRuns: 10, failedRuns: 0,
            overrides: 0, calibrations: 0,
            failuresByChecker: [:], overridesByRiskTier: [:]
        )
        let anomalies = await refiner.detectAnomalies(
            windowSnapshots: [goodSnapshot],
            baselineTrends: [baselineTrend]
        )
        let passAnomaly = anomalies.first { $0.metric == "passRate" }
        #expect(passAnomaly?.metric == "passRate")
        #expect(passAnomaly?.direction == .positive)
    }

    @Test("detectAnomalies: preliminary baseline carries validity")
    func detectAnomaliesPreliminaryBaseline() async {
        let refiner = PulseRefiner(writer: writer)
        let baselineValues: [Double] = [0.09, 0.10, 0.08, 0.11, 0.10, 0.09, 0.12, 0.08, 0.10, 0.11,
                                        0.09, 0.10, 0.08, 0.11, 0.10]
        let baselineTrend = TrendAnalysis.compute(metric: "overrideRate", values: baselineValues)!
        #expect(baselineTrend.validity == .preliminary)

        let outlierSnapshot = DailySnapshot(
            date: makeDayDate("2026-04-28"),
            scope: "test",
            gateRuns: 10, passedRuns: 5, failedRuns: 5,
            overrides: 5, calibrations: 0,
            failuresByChecker: [:], overridesByRiskTier: [:]
        )
        let anomalies = await refiner.detectAnomalies(
            windowSnapshots: [outlierSnapshot],
            baselineTrends: [baselineTrend]
        )
        let overrideAnomaly = anomalies.first { $0.metric == "overrideRate" }
        #expect(overrideAnomaly?.baselineValidity == .preliminary)
    }

    // MARK: - detectClusters

    @Test("detectClusters: 3 occurrences of same ruleId forms cluster")
    func detectClustersBasic() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDate("2026-04-28T10:00:00")
        let metadata = (0..<3).map { _ in
            makeMetadata(timestamp: date, passed: false, failedCheckerIds: ["ConcurrencyAuditor"])
        }
        let calibrations = (0..<2).map { _ in
            makeCalibration(date: date, rootCause: "contextually naive", failedStep: .diagnosis)
        }
        let clusters = await refiner.detectClusters(
            from: metadata, calibrations: calibrations, previousClusters: []
        )
        let cluster = clusters.first { $0.ruleId == "concurrencyauditor.test-rule" }
        #expect(cluster?.ruleId == "concurrencyauditor.test-rule")
        #expect(cluster?.occurrenceCount == 3)
        #expect(cluster?.isRecurring == false)
    }

    @Test("detectClusters: present in previous clusters increments count but needs 3 for recurring")
    func detectClustersRecurring() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDate("2026-04-28T10:00:00")
        let metadata = [
            makeMetadata(projectID: "project-a", timestamp: date, passed: false, failedCheckerIds: ["SafetyAuditor"]),
            makeMetadata(projectID: "project-b", timestamp: date, passed: false, failedCheckerIds: ["SafetyAuditor"]),
        ]
        let previousClusters = [
            ViolationCluster(
                ruleId: "safetyauditor.test-rule",
                occurrenceCount: 5,
                affectedProjectCount: 2,
                dominantRootCause: nil,
                dominantFailedStep: nil,
                isRecurring: true,
                consecutiveAppearances: 5
            )
        ]
        let clusters = await refiner.detectClusters(
            from: metadata, calibrations: [], previousClusters: previousClusters
        )
        let cluster = clusters.first { $0.ruleId == "safetyauditor.test-rule" }
        #expect(cluster?.consecutiveAppearances == 6)
        #expect(cluster?.isRecurring == true)
    }

    @Test("detectClusters: not recurring with only 1 prior appearance (consecutiveAppearances=2)")
    func detectClustersNotRecurringAfterOnePrior() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDate("2026-04-28T10:00:00")
        let metadata = (0..<2).map { _ in
            makeMetadata(timestamp: date, passed: false, failedCheckerIds: ["SafetyAuditor"])
        }
        let previousClusters = [
            ViolationCluster(
                ruleId: "safetyauditor.test-rule",
                occurrenceCount: 5,
                affectedProjectCount: 1,
                dominantRootCause: nil,
                dominantFailedStep: nil,
                isRecurring: false,
                consecutiveAppearances: 1
            )
        ]
        let clusters = await refiner.detectClusters(
            from: metadata, calibrations: [], previousClusters: previousClusters
        )
        let cluster = clusters.first { $0.ruleId == "safetyauditor.test-rule" }
        #expect(cluster?.consecutiveAppearances == 2)
        #expect(cluster?.isRecurring == false)
    }

    @Test("detectClusters: recurring after 3 consecutive appearances across 2+ projects")
    func detectClustersRecurringAfterThree() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDate("2026-04-28T10:00:00")
        let metadata = [
            makeMetadata(projectID: "project-a", timestamp: date, passed: false, failedCheckerIds: ["SafetyAuditor"]),
            makeMetadata(projectID: "project-b", timestamp: date, passed: false, failedCheckerIds: ["SafetyAuditor"]),
        ]
        let previousClusters = [
            ViolationCluster(
                ruleId: "safetyauditor.test-rule",
                occurrenceCount: 5,
                affectedProjectCount: 2,
                dominantRootCause: nil,
                dominantFailedStep: nil,
                isRecurring: false,
                consecutiveAppearances: 2
            )
        ]
        let clusters = await refiner.detectClusters(
            from: metadata, calibrations: [], previousClusters: previousClusters
        )
        let cluster = clusters.first { $0.ruleId == "safetyauditor.test-rule" }
        #expect(cluster?.consecutiveAppearances == 3)
        #expect(cluster?.isRecurring == true)
    }

    @Test("detectClusters: not recurring when only 1 project affected despite 3+ appearances")
    func detectClustersNotRecurringSingleProject() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDate("2026-04-28T10:00:00")
        let metadata = (0..<2).map { _ in
            makeMetadata(timestamp: date, passed: false, failedCheckerIds: ["SafetyAuditor"])
        }
        let previousClusters = [
            ViolationCluster(
                ruleId: "safetyauditor.test-rule",
                occurrenceCount: 5,
                affectedProjectCount: 1,
                dominantRootCause: nil,
                dominantFailedStep: nil,
                isRecurring: false,
                consecutiveAppearances: 4
            )
        ]
        let clusters = await refiner.detectClusters(
            from: metadata, calibrations: [], previousClusters: previousClusters
        )
        let cluster = clusters.first { $0.ruleId == "safetyauditor.test-rule" }
        #expect(cluster?.consecutiveAppearances == 5)
        #expect(cluster?.isRecurring == false)
    }

    @Test("detectClusters: new cluster starts at consecutiveAppearances=1")
    func detectClustersNewClusterStartsAtOne() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDate("2026-04-28T10:00:00")
        let metadata = (0..<3).map { _ in
            makeMetadata(timestamp: date, passed: false, failedCheckerIds: ["ConcurrencyAuditor"])
        }
        let clusters = await refiner.detectClusters(
            from: metadata, calibrations: [], previousClusters: []
        )
        let cluster = clusters.first { $0.ruleId == "concurrencyauditor.test-rule" }
        #expect(cluster?.consecutiveAppearances == 1)
        #expect(cluster?.isRecurring == false)
    }

    @Test("detectClusters: prior cluster without consecutiveAppearances defaults to 1")
    func detectClustersLegacyPriorDefaults() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDate("2026-04-28T10:00:00")
        let metadata = (0..<2).map { _ in
            makeMetadata(timestamp: date, passed: false, failedCheckerIds: ["SafetyAuditor"])
        }
        let previousClusters = [
            ViolationCluster(
                ruleId: "safetyauditor.test-rule",
                occurrenceCount: 5,
                affectedProjectCount: 1,
                dominantRootCause: nil,
                dominantFailedStep: nil,
                isRecurring: false
            )
        ]
        let clusters = await refiner.detectClusters(
            from: metadata, calibrations: [], previousClusters: previousClusters
        )
        let cluster = clusters.first { $0.ruleId == "safetyauditor.test-rule" }
        #expect(cluster?.consecutiveAppearances == 2)
        #expect(cluster?.isRecurring == false)
    }

    // MARK: - Dominant root cause

    @Test("Dominant root cause picks highest count, ties broken lexicographically")
    func dominantRootCause() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDate("2026-04-28T10:00:00")
        let metadata = (0..<3).map { _ in
            makeMetadata(timestamp: date, passed: false, failedCheckerIds: ["ConcurrencyAuditor"])
        }
        let calibrations = [
            makeCalibration(date: date, rootCause: "contextually naive"),
            makeCalibration(date: date, rootCause: "contextually naive"),
            makeCalibration(date: date, rootCause: "expedient"),
        ]
        let clusters = await refiner.detectClusters(
            from: metadata, calibrations: calibrations, previousClusters: []
        )
        let cluster = clusters.first { $0.ruleId == "concurrencyauditor.test-rule" }
        #expect(cluster?.dominantRootCause == "contextually naive")
    }

    // MARK: - refine integration

    @Test("refine golden path: produces Pulse with statistics")
    func refineGoldenPath() async throws {
        let corpus = CorpusPath(
            basePath: FileManager.default.temporaryDirectory
                .appendingPathComponent("ijs-refiner-test-\(UUID().uuidString)").path,
            projectID: "test-project"
        )
        let refiner = PulseRefiner(writer: writer)

        for day in 21...27 {
            let ts = makeDate("2026-04-\(day)T10:00:00")
            let md = makeMetadata(projectID: "test-project", timestamp: ts, passed: day % 3 != 0, failedCheckerIds: day % 3 == 0 ? ["SafetyAuditor"] : [])
            try await writer.write(metadata: md, calibrations: [], to: corpus)
        }

        let pulse = try await refiner.refine(
            from: [corpus],
            windowStart: makeDayDate("2026-04-21"),
            windowEnd: makeDayDate("2026-04-28"),
            previousPulse: nil,
            lookbackDays: 90
        )
        #expect(pulse.weekLabel.contains("W"))
        #expect(pulse.statistics.totalGateRuns == 7)
        #expect(pulse.projects == ["test-project"])
        #expect(pulse.narrative == nil)
    }

    @Test("refine empty corpus: zero statistics")
    func refineEmptyCorpus() async throws {
        let corpus = CorpusPath(
            basePath: FileManager.default.temporaryDirectory
                .appendingPathComponent("ijs-refiner-empty-\(UUID().uuidString)").path,
            projectID: "empty-project"
        )
        let refiner = PulseRefiner(writer: writer)

        let pulse = try await refiner.refine(
            from: [corpus],
            windowStart: makeDayDate("2026-04-21"),
            windowEnd: makeDayDate("2026-04-28"),
            previousPulse: nil
        )
        #expect(pulse.statistics.totalGateRuns == 0)
        #expect(pulse.statistics.corpusTrends.isEmpty)
        #expect(pulse.statistics.anomalies.isEmpty)
    }
}
