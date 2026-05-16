import Testing
import Foundation
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("CorpusReader Pulse Loading")
struct CorpusReaderPulseTests {

    @Test("loadLatestPulse returns most recent pulse")
    func loadLatestPulse() throws {
        let corpus = try makeCorpusWithPulses(weekLabels: ["2026-W18", "2026-W19", "2026-W20"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = try #require(reader.loadLatestPulse())
        #expect(pulse.weekLabel == "2026-W20")
    }

    @Test("loadLatestPulse returns nil when no pulse directory exists")
    func loadLatestPulseNoPulseDir() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "\(tmp)/telemetry", withIntermediateDirectories: true)
        let reader = CorpusReader(corpusPath: tmp)
        let pulse = reader.loadLatestPulse()
        #expect(pulse == nil)
    }

    @Test("loadLatestPulse returns nil when pulse directory is empty")
    func loadLatestPulseEmptyDir() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "\(tmp)/pulse", withIntermediateDirectories: true)
        let reader = CorpusReader(corpusPath: tmp)
        let pulse = reader.loadLatestPulse()
        #expect(pulse == nil)
    }

    @Test("loadPulse returns specific week")
    func loadPulseByWeekLabel() throws {
        let corpus = try makeCorpusWithPulses(weekLabels: ["2026-W18", "2026-W19"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = try #require(reader.loadPulse(weekLabel: "2026-W18"))
        #expect(pulse.weekLabel == "2026-W18")
    }

    @Test("loadPulse returns nil for missing week")
    func loadPulseMissingWeek() throws {
        let corpus = try makeCorpusWithPulses(weekLabels: ["2026-W18"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = reader.loadPulse(weekLabel: "2026-W99")
        #expect(pulse == nil)
    }

    @Test("loadLatestPulse skips malformed JSON")
    func loadLatestPulseSkipsMalformed() throws {
        let corpus = try makeCorpusWithPulses(weekLabels: ["2026-W18"])
        let badDir = "\(corpus)/pulse/2026-W19"
        try FileManager.default.createDirectory(atPath: badDir, withIntermediateDirectories: true)
        try "not json".write(toFile: "\(badDir)/PULSE_2026-W19.json", atomically: true, encoding: .utf8)

        let reader = CorpusReader(corpusPath: corpus)
        let pulse = try #require(reader.loadLatestPulse())
        #expect(pulse.weekLabel == "2026-W18")
    }

    @Test("loadLatestPulse preserves pulse statistics")
    func loadLatestPulsePreservesStats() throws {
        let corpus = try makeCorpusWithPulses(weekLabels: ["2026-W20"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = reader.loadLatestPulse()
        #expect(pulse?.statistics.totalGateRuns == 100)
        #expect(pulse?.statistics.passedRuns == 60)
        #expect(pulse?.statistics.failedRuns == 40)
    }

    @Test("loadLatestPulse preserves violation clusters")
    func loadLatestPulsePreservesClusters() throws {
        let corpus = try makeCorpusWithPulses(weekLabels: ["2026-W20"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = reader.loadLatestPulse()
        #expect(pulse?.violationClusters.count == 1)
        #expect(pulse?.violationClusters.first?.ruleId == "force-unwrap")
    }
}

// MARK: - Helpers

private func makeCorpusWithPulses(weekLabels: [String]) throws -> String {
    let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: "\(tmp)/telemetry", withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    for label in weekLabels {
        let pulseDir = "\(tmp)/pulse/\(label)"
        try fm.createDirectory(atPath: pulseDir, withIntermediateDirectories: true)

        let pulse = InstitutionalPulse(
            windowStart: Date(timeIntervalSince1970: 1747267200),
            windowEnd: Date(timeIntervalSince1970: 1747871999),
            weekLabel: label,
            projects: ["projectA", "projectB"],
            statistics: PulseStatistics(
                totalGateRuns: 100, passedRuns: 60, failedRuns: 40,
                totalOverrides: 5, totalCalibrations: 2,
                overridesByRiskTier: [:], failuresByChecker: ["safety": 25],
                rootCauseDistribution: [:], failedStepDistribution: [:],
                meanConsistencyScore: 0.85, corpusTrends: [], projectTrends: [:],
                anomalies: [], corpusSnapshots: [], projectSnapshots: [:]
            ),
            violationClusters: [
                ViolationCluster(ruleId: "force-unwrap", occurrenceCount: 50, affectedProjectCount: 10, dominantRootCause: nil, dominantFailedStep: nil, isRecurring: true),
            ],
            proposedPolicyUpdates: ["Add concurrency rule"],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: Date(timeIntervalSince1970: 1747958400)
        )
        let data = try encoder.encode(pulse)
        try data.write(to: URL(fileURLWithPath: "\(pulseDir)/PULSE_\(label).json"))
    }

    return tmp
}
