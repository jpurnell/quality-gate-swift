import Testing
import Foundation
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("CorpusReader Label-Aware Pulse Loading")
struct CorpusReaderLabelTests {

    // MARK: - listAvailableLabels

    @Test("listAvailableLabels returns week labels sorted chronologically")
    func listWeekLabelsOnly() throws {
        let corpus = try makeCorpusWithLabels(labels: ["2026-W20", "2026-W18", "2026-W19"])
        let reader = CorpusReader(corpusPath: corpus)
        let labels = reader.listAvailableLabels()
        #expect(labels == ["2026-W18", "2026-W19", "2026-W20"])
    }

    @Test("listAvailableLabels returns date labels sorted chronologically")
    func listDateLabelsOnly() throws {
        let corpus = try makeCorpusWithLabels(labels: ["2026-06-05", "2026-06-01", "2026-06-03"])
        let reader = CorpusReader(corpusPath: corpus)
        let labels = reader.listAvailableLabels()
        #expect(labels == ["2026-06-01", "2026-06-03", "2026-06-05"])
    }

    @Test("listAvailableLabels returns mixed labels sorted chronologically")
    func listMixedLabels() throws {
        // W22 = Monday 2026-05-25, 2026-06-05 is in W23
        let corpus = try makeCorpusWithLabels(labels: ["2026-06-05", "2026-W22", "2026-06-01"])
        let reader = CorpusReader(corpusPath: corpus)
        let labels = reader.listAvailableLabels()
        // W22 Monday = 2026-05-25, then 2026-06-01, then 2026-06-05
        #expect(labels == ["2026-W22", "2026-06-01", "2026-06-05"])
    }

    @Test("listAvailableLabels returns empty when no pulse directory")
    func listLabelsNoPulseDir() throws {
        let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "\(tmp)/telemetry", withIntermediateDirectories: true)
        let reader = CorpusReader(corpusPath: tmp)
        let labels = reader.listAvailableLabels()
        #expect(labels.isEmpty)
    }

    @Test("listAvailableLabels skips directories without valid pulse JSON")
    func listLabelsSkipsInvalid() throws {
        let corpus = try makeCorpusWithLabels(labels: ["2026-W18", "2026-06-05"])
        let emptyDir = "\(corpus)/pulse/2026-06-03"
        try FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
        let reader = CorpusReader(corpusPath: corpus)
        let labels = reader.listAvailableLabels()
        #expect(labels == ["2026-W18", "2026-06-05"])
    }

    // MARK: - listAvailableWeeks backward compat

    @Test("listAvailableWeeks returns same results as listAvailableLabels")
    func listWeeksBackwardCompat() throws {
        let corpus = try makeCorpusWithLabels(labels: ["2026-W20", "2026-06-05"])
        let reader = CorpusReader(corpusPath: corpus)
        #expect(reader.listAvailableWeeks() == reader.listAvailableLabels())
    }

    // MARK: - loadPulse(label:)

    @Test("loadPulse by date label returns correct pulse")
    func loadPulseByDateLabel() throws {
        let corpus = try makeCorpusWithLabels(labels: ["2026-06-05", "2026-W22"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = try #require(reader.loadPulse(label: "2026-06-05"))
        #expect(pulse.weekLabel == "2026-06-05")
    }

    @Test("loadPulse by week label returns correct pulse")
    func loadPulseByWeekLabel() throws {
        let corpus = try makeCorpusWithLabels(labels: ["2026-06-05", "2026-W22"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = try #require(reader.loadPulse(label: "2026-W22"))
        #expect(pulse.weekLabel == "2026-W22")
    }

    @Test("loadPulse returns nil for missing label")
    func loadPulseMissingLabel() throws {
        let corpus = try makeCorpusWithLabels(labels: ["2026-W18"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = reader.loadPulse(label: "2026-06-01")
        #expect(pulse == nil)
    }

    @Test("loadPulse(weekLabel:) delegates to loadPulse(label:)")
    func loadPulseWeekLabelDelegates() throws {
        let corpus = try makeCorpusWithLabels(labels: ["2026-W22"])
        let reader = CorpusReader(corpusPath: corpus)
        let byLabel = reader.loadPulse(label: "2026-W22")
        let byWeek = reader.loadPulse(weekLabel: "2026-W22")
        #expect(byLabel == byWeek)
    }

    // MARK: - loadLatestPulse with mixed labels

    @Test("loadLatestPulse returns chronologically latest across mixed labels")
    func loadLatestMixed() throws {
        // W22 = 2026-05-25, 2026-06-05 is later
        let corpus = try makeCorpusWithLabels(labels: ["2026-W22", "2026-06-05"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = try #require(reader.loadLatestPulse())
        #expect(pulse.weekLabel == "2026-06-05")
    }

    @Test("loadLatestPulse returns week pulse when it is latest")
    func loadLatestWeekIsLatest() throws {
        // W23 = 2026-06-01, 2026-05-20 is earlier
        let corpus = try makeCorpusWithLabels(labels: ["2026-05-20", "2026-W23"])
        let reader = CorpusReader(corpusPath: corpus)
        let pulse = try #require(reader.loadLatestPulse())
        #expect(pulse.weekLabel == "2026-W23")
    }

    // MARK: - parseLabelDate

    @Test("parseLabelDate parses YYYY-MM-DD format")
    func parseDateFormat() {
        let date = CorpusReader.parseLabelDate("2026-06-05")
        #expect(date != nil)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        #expect(fmt.string(from: date!) == "2026-06-05")
    }

    @Test("parseLabelDate parses YYYY-WNN format to Monday")
    func parseWeekFormat() {
        let date = CorpusReader.parseLabelDate("2026-W22")
        #expect(date != nil)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        #expect(fmt.string(from: date!) == "2026-05-25")
    }

    @Test("parseLabelDate returns nil for unrecognized format")
    func parseInvalidFormat() {
        #expect(CorpusReader.parseLabelDate("not-a-label") == nil)
        #expect(CorpusReader.parseLabelDate("2026") == nil)
        #expect(CorpusReader.parseLabelDate("") == nil)
    }
}

// MARK: - Helpers

private func makeCorpusWithLabels(labels: [String]) throws -> String {
    let tmp = NSTemporaryDirectory() + "ijs-test-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: "\(tmp)/telemetry", withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    for label in labels {
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
