import Testing
import Foundation
import QualityGateTypes
@testable import IJSRefiner
import IJSSensor
import IJSAggregator

@Suite("PulseStatisticalMaturityIntegration")
struct PulseStatisticalMaturityIntegrationTests {

    private let writer = TelemetryWriter()

    // MARK: - Date Helpers

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

    // MARK: - Metadata Factory

    private static let baseCheckerIds = [
        "build", "test", "safety", "doc-coverage", "unreachable",
        "recursion", "concurrency", "pointer-escape", "logging", "fp-safety",
    ]

    private func makeMetadata(
        projectID: String,
        timestamp: Date,
        passed: Bool = true,
        failedCheckerIds: [String] = []
    ) -> CheckResultMetadata {
        let failedSet = Set(failedCheckerIds)
        var results: [CheckResult] = []
        for checkerId in Self.baseCheckerIds {
            let failed = failedSet.contains(checkerId)
            results.append(CheckResult(
                checkerId: checkerId,
                status: failed ? .failed : .passed,
                diagnostics: failed ? [Diagnostic(
                    severity: .error,
                    message: "Test failure in \(checkerId)",
                    filePath: "Source.swift",
                    lineNumber: 1,
                    ruleId: "\(checkerId.lowercased()).rule"
                )] : [],
                duration: .zero
            ))
        }
        for checkerId in failedCheckerIds where !Self.baseCheckerIds.contains(checkerId) {
            results.append(CheckResult(
                checkerId: checkerId,
                status: .failed,
                diagnostics: [Diagnostic(
                    severity: .error,
                    message: "Test failure in \(checkerId)",
                    filePath: "Source.swift",
                    lineNumber: 1,
                    ruleId: "\(checkerId.lowercased()).rule"
                )],
                duration: .zero
            ))
        }

        return CheckResultMetadata(
            projectID: projectID,
            timestamp: timestamp,
            environment: .local,
            decisionOwner: "test",
            results: results,
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil
        )
    }

    // MARK: - Temp Directory Helper

    private func makeTempCorpusRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ijs-maturity-integration-\(UUID().uuidString)")
            .path
    }

    // MARK: - End-to-End Integration Test

    @Test("Full pipeline: tiers, scores, trajectories, groups, label, round-trip")
    func fullPipelineIntegration() async throws {
        let corpusRoot = makeTempCorpusRoot()

        // Window: 2026-05-26 to 2026-06-05 (11 calendar days)
        let windowStart = makeDayDate("2026-05-26")
        let windowEnd = makeDayDate("2026-06-05")

        let corpusActive = CorpusPath(basePath: corpusRoot, projectID: "ProjectActive")
        let corpusFirstContact = CorpusPath(basePath: corpusRoot, projectID: "ProjectFirstContact")
        let corpusDormant = CorpusPath(basePath: corpusRoot, projectID: "ProjectDormant")

        // --- Step 1: Write metadata for ProjectActive (10 runs over 10 days) ---
        for day in 26...31 {
            let ts = makeDate("2026-05-\(String(format: "%02d", day))T10:00:00")
            let passed = day % 3 != 0 // days 27, 30 fail
            let failed: [String] = passed ? [] : ["safety"]
            let md = makeMetadata(
                projectID: "ProjectActive",
                timestamp: ts,
                passed: passed,
                failedCheckerIds: failed
            )
            try await writer.write(metadata: md, calibrations: [], to: corpusActive)
        }
        for day in 1...4 {
            let ts = makeDate("2026-06-\(String(format: "%02d", day))T10:00:00")
            let passed = day % 2 == 0 // days 1, 3 fail
            let failed: [String] = passed ? [] : ["concurrency"]
            let md = makeMetadata(
                projectID: "ProjectActive",
                timestamp: ts,
                passed: passed,
                failedCheckerIds: failed
            )
            try await writer.write(metadata: md, calibrations: [], to: corpusActive)
        }

        // --- Step 2: Write metadata for ProjectFirstContact (2 runs, recent) ---
        let fc1 = makeMetadata(
            projectID: "ProjectFirstContact",
            timestamp: makeDate("2026-06-03T14:00:00"),
            passed: true
        )
        try await writer.write(metadata: fc1, calibrations: [], to: corpusFirstContact)

        let fc2 = makeMetadata(
            projectID: "ProjectFirstContact",
            timestamp: makeDate("2026-06-04T09:00:00"),
            passed: false,
            failedCheckerIds: ["build"]
        )
        try await writer.write(metadata: fc2, calibrations: [], to: corpusFirstContact)

        // --- Step 3: Write metadata for ProjectDormant (1 run, 35 days old) ---
        let dormantTs = makeDate("2026-04-28T08:00:00")
        let dormantMd = makeMetadata(
            projectID: "ProjectDormant",
            timestamp: dormantTs,
            passed: true
        )
        try await writer.write(metadata: dormantMd, calibrations: [], to: corpusDormant)

        // --- Step 4: Write manifest with groups ---
        let manifestDir = URL(fileURLWithPath: corpusRoot)
        try FileManager.default.createDirectory(
            at: manifestDir,
            withIntermediateDirectories: true
        )
        let manifestContent = """
        projects: {}
        groups:
          TestGroup:
            - ProjectActive
            - ProjectFirstContact
        """
        let manifestURL = manifestDir.appendingPathComponent("manifest.yml")
        try manifestContent.write(to: manifestURL, atomically: true, encoding: .utf8)
        let manifest = try CorpusManifest.load(from: manifestURL)

        // --- Step 5: Run refine() ---
        let refiner = PulseRefiner(writer: writer)
        let pulse = try await refiner.refine(
            from: [corpusActive, corpusFirstContact, corpusDormant],
            windowStart: windowStart,
            windowEnd: windowEnd,
            previousPulse: nil,
            lookbackDays: 90,
            manifest: manifest,
            label: "2026-06-05"
        )

        // --- Step 6: Verify label ---
        #expect(pulse.label == "2026-06-05")
        #expect(pulse.weekLabel.contains("W"))

        // --- Step 7: Verify project tiers ---
        let tiers = try #require(pulse.projectTiers)
        #expect(tiers["ProjectActive"] == .active)
        #expect(tiers["ProjectFirstContact"] == .firstContact)
        // ProjectDormant's only run is outside the window (April 28),
        // but since refine reads from lookbackStart..windowEnd, the dormant project
        // snapshots exist from lookback. The classifyProjects method computes
        // daysSinceLastRun from snapshot date to windowEnd.
        // April 28 to June 5 = 38 days => dormant
        #expect(tiers["ProjectDormant"] == .dormant)

        // --- Step 8: Verify weighted scores ---
        let weightedScores = try #require(pulse.statistics.weightedScores)
        // ProjectActive has runs in the window => should have a weighted score
        let activeScore = try #require(weightedScores["ProjectActive"])
        #expect(activeScore >= 0.0 && activeScore <= 1.0)
        // ProjectFirstContact has runs in the window => should have a weighted score
        let fcScore = try #require(weightedScores["ProjectFirstContact"])
        #expect(fcScore >= 0.0 && fcScore <= 1.0)
        // ProjectDormant's single run is outside the window => no window metadata => no score
        #expect(weightedScores["ProjectDormant"] == nil)

        // Weighted scores should be between 0 and 1
        for (_, score) in weightedScores {
            #expect(score >= 0.0 && score <= 1.0)
        }

        // --- Step 9: Verify project trajectories ---
        let trajectories = try #require(pulse.projectTrajectories)
        // ProjectActive has 10 runs => enough for trajectory analysis
        let activeTrajectory = try #require(trajectories.first { $0.projectID == "ProjectActive" })
        #expect(activeTrajectory.sampleSize == 10)
        #expect(activeTrajectory.direction != .insufficient)

        // ProjectFirstContact has only 2 runs in window => trajectory with insufficient direction
        let fcTrajectory = try #require(trajectories.first { $0.projectID == "ProjectFirstContact" })
        #expect(fcTrajectory.sampleSize == 2)
        #expect(fcTrajectory.direction == .insufficient)

        // --- Step 10: Verify group snapshots ---
        let groupSnaps = try #require(pulse.groupSnapshots)
        let testGroupSnaps = try #require(groupSnaps["TestGroup"])
        #expect(!testGroupSnaps.isEmpty)
        // Group snapshots should merge ProjectActive + ProjectFirstContact daily data
        let totalGroupRuns = testGroupSnaps.reduce(0) { $0 + $1.gateRuns }
        // ProjectActive contributes 10 runs in window, ProjectFirstContact contributes 2
        #expect(totalGroupRuns == 12)

        // --- Step 11: Verify statistics ---
        #expect(pulse.statistics.totalGateRuns > 0)
        // Only window metadata is counted: 10 (active) + 2 (firstContact) = 12
        // ProjectDormant's run is in the lookback period, not the window
        #expect(pulse.statistics.totalGateRuns == 12)

        // --- Step 12: Verify gated anomalies (may or may not be present) ---
        // If anomalies are detected, they should be gated
        if let gated = pulse.statistics.gatedAnomalies {
            for gate in gated {
                #expect([GatedSeverity.confirmed, .directional, .unreliable].contains(gate.gatedSeverity))
                #expect([Actionability.investigate, .monitor, .deferAction, .explained].contains(gate.actionability))
            }
        }

        // --- Step 13: Write + Read round-trip ---
        try await writer.writePulse(pulse, to: corpusActive)
        let readBack = try await writer.readLatestPulse(from: corpusActive)
        let roundTripped = try #require(readBack)

        #expect(roundTripped.label == pulse.label)
        #expect(roundTripped.weekLabel == pulse.weekLabel)
        #expect(roundTripped.projects == pulse.projects)
        #expect(roundTripped.statistics.totalGateRuns == pulse.statistics.totalGateRuns)
        #expect(roundTripped.projectTiers == pulse.projectTiers)
        #expect(roundTripped.projectTrajectories == pulse.projectTrajectories)
        // Verify group snapshots round-trip
        #expect(roundTripped.groupSnapshots?["TestGroup"]?.count == pulse.groupSnapshots?["TestGroup"]?.count)

        // --- Cleanup ---
        try? FileManager.default.removeItem(atPath: corpusRoot)
    }

    // MARK: - Backward Compatibility

    @Test("Backward compatibility: pulse JSON without label field deserializes with label == nil")
    func backwardCompatibilityNoLabel() throws {
        // Construct a minimal pulse JSON using only weekLabel (no label field).
        // Note: [RiskTier: Int] and [FiveStepStage: Int] encode as arrays of
        // key-value pairs, not as JSON objects, because their keys are not strings.
        let pulseJSON = """
        {
            "windowStart": "2026-05-19T00:00:00Z",
            "windowEnd": "2026-05-26T00:00:00Z",
            "weekLabel": "2026-W21",
            "projects": ["OldProject"],
            "statistics": {
                "totalGateRuns": 5,
                "passedRuns": 4,
                "failedRuns": 1,
                "totalOverrides": 0,
                "totalCalibrations": 0,
                "overridesByRiskTier": [],
                "failuresByChecker": {},
                "rootCauseDistribution": {},
                "failedStepDistribution": [],
                "corpusTrends": [],
                "projectTrends": {},
                "anomalies": [],
                "corpusSnapshots": [],
                "projectSnapshots": {}
            },
            "violationClusters": [],
            "proposedPolicyUpdates": [],
            "calibrationSummaries": [],
            "generatedAt": "2026-05-26T12:00:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(pulseJSON.utf8)
        let pulse = try decoder.decode(InstitutionalPulse.self, from: data)

        #expect(pulse.label == nil)
        #expect(pulse.weekLabel == "2026-W21")
        #expect(pulse.projects == ["OldProject"])
        #expect(pulse.statistics.totalGateRuns == 5)
        #expect(pulse.projectTiers == nil)
        #expect(pulse.projectTrajectories == nil)
        #expect(pulse.groupSnapshots == nil)
    }

    // MARK: - Tier Classification Edge Cases

    @Test("Tier classification: at-risk project (21-29 days since last run)")
    func atRiskTierClassification() async throws {
        let corpusRoot = makeTempCorpusRoot()
        let windowEnd = makeDayDate("2026-06-05")

        let corpusAtRisk = CorpusPath(basePath: corpusRoot, projectID: "ProjectAtRisk")

        // Write a single run from 25 days ago (within lookback, making daysSinceLastRun ~25)
        // May 11 to June 5 = 25 days => atRisk (>= 21, < 30)
        let atRiskTs = makeDate("2026-05-11T10:00:00")
        let md = makeMetadata(
            projectID: "ProjectAtRisk",
            timestamp: atRiskTs,
            passed: true
        )
        try await writer.write(metadata: md, calibrations: [], to: corpusAtRisk)

        let refiner = PulseRefiner(writer: writer)

        // The run on May 11 is before windowStart (May 26), so it falls into baseline only.
        // classifyProjects looks at projectSnapshots built from window metadata only.
        // With a narrow window starting May 26, ProjectAtRisk has no window metadata.
        // Verify through a wider window that includes May 11.
        let wideWindowStart = makeDayDate("2026-05-01")
        let pulseWide = try await refiner.refine(
            from: [corpusAtRisk],
            windowStart: wideWindowStart,
            windowEnd: windowEnd,
            previousPulse: nil,
            lookbackDays: 90
        )

        let tiers = try #require(pulseWide.projectTiers)
        #expect(tiers["ProjectAtRisk"] == .atRisk)

        try? FileManager.default.removeItem(atPath: corpusRoot)
    }

    // MARK: - Weighted Scoring Verification

    @Test("Weighted scoring: all-pass project scores 1.0, mixed project scores < 1.0")
    func weightedScoringValues() async throws {
        let corpusRoot = makeTempCorpusRoot()
        let windowStart = makeDayDate("2026-06-01")
        let windowEnd = makeDayDate("2026-06-05")

        let corpusPerfect = CorpusPath(basePath: corpusRoot, projectID: "PerfectProject")
        let corpusMixed = CorpusPath(basePath: corpusRoot, projectID: "MixedProject")

        // PerfectProject: 3 all-pass runs
        for day in 1...3 {
            let ts = makeDate("2026-06-\(String(format: "%02d", day))T10:00:00")
            let md = makeMetadata(
                projectID: "PerfectProject",
                timestamp: ts,
                passed: true
            )
            try await writer.write(metadata: md, calibrations: [], to: corpusPerfect)
        }

        // MixedProject: 3 runs, all with a safety failure
        for day in 1...3 {
            let ts = makeDate("2026-06-\(String(format: "%02d", day))T11:00:00")
            let md = makeMetadata(
                projectID: "MixedProject",
                timestamp: ts,
                passed: false,
                failedCheckerIds: ["safety"]
            )
            try await writer.write(metadata: md, calibrations: [], to: corpusMixed)
        }

        let refiner = PulseRefiner(writer: writer)
        let pulse = try await refiner.refine(
            from: [corpusPerfect, corpusMixed],
            windowStart: windowStart,
            windowEnd: windowEnd,
            previousPulse: nil,
            lookbackDays: 90
        )

        let scores = try #require(pulse.statistics.weightedScores)
        let perfectScore = try #require(scores["PerfectProject"])
        let mixedScore = try #require(scores["MixedProject"])

        // All-pass => score should be 1.0
        #expect(abs(perfectScore - 1.0) < 1e-10)
        // Mixed (build passes, safety fails) => score < 1.0
        #expect(mixedScore < 1.0)
        #expect(mixedScore > 0.0)

        try? FileManager.default.removeItem(atPath: corpusRoot)
    }
}
