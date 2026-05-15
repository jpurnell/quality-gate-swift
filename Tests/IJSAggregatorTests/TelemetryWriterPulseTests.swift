import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor

@Suite("TelemetryWriter Pulse I/O")
struct TelemetryWriterPulseTests {

    private let writer = TelemetryWriter()

    private func makeTempCorpusPath() -> CorpusPath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ijs-pulse-test-\(UUID().uuidString)")
            .path
        return CorpusPath(basePath: base, projectID: "test-project")
    }

    private func makePulse(weekLabel: String = "2026-W18") -> InstitutionalPulse {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let stats = PulseStatistics(
            totalGateRuns: 10,
            passedRuns: 8,
            failedRuns: 2,
            totalOverrides: 1,
            totalCalibrations: 1,
            overridesByRiskTier: [.safety: 1],
            failuresByChecker: ["SafetyAuditor": 2],
            rootCauseDistribution: ["systemic": 1],
            failedStepDistribution: [.diagnosis: 1],
            meanConsistencyScore: 0.85,
            corpusTrends: [],
            projectTrends: [:],
            anomalies: [],
            corpusSnapshots: [],
            projectSnapshots: [:]
        )

        return InstitutionalPulse(
            windowStart: fmt.date(from: "2026-04-27")!,
            windowEnd: fmt.date(from: "2026-05-04")!,
            weekLabel: weekLabel,
            projects: ["test-project"],
            statistics: stats,
            violationClusters: [],
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: fmt.date(from: "2026-05-04")!
        )
    }

    @Test("writePulse creates file at correct path")
    func writeCreatesFile() async throws {
        let corpus = makeTempCorpusPath()
        let pulse = makePulse()
        try await writer.writePulse(pulse, to: corpus)

        let expectedPath = corpus.pulsePath(weekLabel: pulse.weekLabel)
        let resolved = URL(fileURLWithPath: expectedPath).standardized.resolvingSymlinksInPath()
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }

    @Test("writePulse and readLatestPulse round-trip")
    func roundTrip() async throws {
        let corpus = makeTempCorpusPath()
        let pulse = makePulse()
        try await writer.writePulse(pulse, to: corpus)

        let latest = try await writer.readLatestPulse(from: corpus)
        #expect(latest?.weekLabel == pulse.weekLabel)
        #expect(latest == pulse)
    }

    @Test("readLatestPulse returns nil when no pulse exists")
    func noPulseReturnsNil() async throws {
        let corpus = makeTempCorpusPath()
        let latest = try await writer.readLatestPulse(from: corpus)
        #expect(latest == nil)
    }

    @Test("readLatestPulse returns most recent week")
    func returnsLatestWeek() async throws {
        let corpus = makeTempCorpusPath()
        let older = makePulse(weekLabel: "2026-W16")
        let newer = makePulse(weekLabel: "2026-W18")
        try await writer.writePulse(older, to: corpus)
        try await writer.writePulse(newer, to: corpus)

        let latest = try await writer.readLatestPulse(from: corpus)
        #expect(latest?.weekLabel == "2026-W18")
    }

    @Test("writePulse overwrites same week label")
    func overwriteSameWeek() async throws {
        let corpus = makeTempCorpusPath()
        let first = makePulse(weekLabel: "2026-W18")

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let updated = InstitutionalPulse(
            windowStart: fmt.date(from: "2026-04-27")!,
            windowEnd: fmt.date(from: "2026-05-04")!,
            weekLabel: "2026-W18",
            projects: ["test-project", "second-project"],
            statistics: first.statistics,
            violationClusters: [],
            proposedPolicyUpdates: ["add concurrency rule"],
            calibrationSummaries: [],
            narrative: "Updated pulse",
            generatedAt: fmt.date(from: "2026-05-04")!
        )

        try await writer.writePulse(first, to: corpus)
        try await writer.writePulse(updated, to: corpus)

        let latest = try await writer.readLatestPulse(from: corpus)
        #expect(latest?.projects.count == 2)
        #expect(latest?.narrative == "Updated pulse")
    }

    @Test("writePulse path sanitization prevents traversal")
    func pathSanitization() async throws {
        let corpus = makeTempCorpusPath()
        let malicious = InstitutionalPulse(
            windowStart: Date(),
            windowEnd: Date(),
            weekLabel: "../../../etc",
            projects: [],
            statistics: PulseStatistics(
                totalGateRuns: 0, passedRuns: 0, failedRuns: 0,
                totalOverrides: 0, totalCalibrations: 0,
                overridesByRiskTier: [:], failuresByChecker: [:],
                rootCauseDistribution: [:], failedStepDistribution: [:],
                meanConsistencyScore: nil, corpusTrends: [], projectTrends: [:],
                anomalies: [], corpusSnapshots: [], projectSnapshots: [:]
            ),
            violationClusters: [],
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: Date()
        )
        await #expect(throws: IJSError.self) {
            try await writer.writePulse(malicious, to: corpus)
        }
    }
}
