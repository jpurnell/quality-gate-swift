import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor

@Suite("TelemetryWriter Label-Aware Pulse I/O")
struct TelemetryWriterLabelTests {

    private let writer = TelemetryWriter()

    private func makeTempCorpusPath() -> CorpusPath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ijs-label-test-\(UUID().uuidString)")
            .path
        return CorpusPath(basePath: base, projectID: "test-project")
    }

    private func makePulse(weekLabel: String = "2026-W22", label: String? = nil) -> InstitutionalPulse {
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
            windowStart: fmt.date(from: "2026-05-25")!,
            windowEnd: fmt.date(from: "2026-06-01")!,
            weekLabel: weekLabel,
            label: label,
            projects: ["test-project"],
            statistics: stats,
            violationClusters: [],
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: fmt.date(from: "2026-06-01")!
        )
    }

    // MARK: - Write with date label

    @Test("writePulse with date label creates file at date-labeled path")
    func writeDateLabel() async throws {
        let corpus = makeTempCorpusPath()
        let pulse = makePulse(weekLabel: "2026-W22", label: "2026-06-05")
        try await writer.writePulse(pulse, to: corpus)

        let expectedPath = corpus.pulsePath(weekLabel: "2026-06-05")
        let resolved = URL(fileURLWithPath: expectedPath).standardized.resolvingSymlinksInPath()
        #expect(FileManager.default.fileExists(atPath: resolved.path))

        // Verify the week-label path does NOT exist (label takes priority)
        let weekPath = corpus.pulsePath(weekLabel: "2026-W22")
        let weekResolved = URL(fileURLWithPath: weekPath).standardized.resolvingSymlinksInPath()
        #expect(!FileManager.default.fileExists(atPath: weekResolved.path))
    }

    // MARK: - Write without label (backward compat)

    @Test("writePulse without label falls back to weekLabel")
    func writeNoLabel() async throws {
        let corpus = makeTempCorpusPath()
        let pulse = makePulse(weekLabel: "2026-W22", label: nil)
        try await writer.writePulse(pulse, to: corpus)

        let expectedPath = corpus.pulsePath(weekLabel: "2026-W22")
        let resolved = URL(fileURLWithPath: expectedPath).standardized.resolvingSymlinksInPath()
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }

    // MARK: - Mixed labels: readLatestPulse chronological ordering

    @Test("readLatestPulse picks chronologically latest across mixed labels")
    func readLatestMixed() async throws {
        let corpus = makeTempCorpusPath()

        // 2026-W22 starts Monday 2026-05-25
        let weekPulse = makePulse(weekLabel: "2026-W22", label: nil)
        // 2026-06-05 is a Thursday in W23, strictly later than W22
        let datePulse = makePulse(weekLabel: "2026-W23", label: "2026-06-05")
        // 2026-06-01 is a Sunday in W22, same week but later day
        let earlyDatePulse = makePulse(weekLabel: "2026-W22", label: "2026-06-01")

        try await writer.writePulse(weekPulse, to: corpus)
        try await writer.writePulse(datePulse, to: corpus)
        try await writer.writePulse(earlyDatePulse, to: corpus)

        let latest = try await writer.readLatestPulse(from: corpus)
        // 2026-06-05 is the latest date chronologically
        #expect(latest?.label == "2026-06-05")
    }

    @Test("readLatestPulse returns week-labeled pulse when it is latest")
    func readLatestWeekIsLatest() async throws {
        let corpus = makeTempCorpusPath()

        // 2026-05-20 is a Wednesday, early
        let datePulse = makePulse(weekLabel: "2026-W21", label: "2026-05-20")
        // 2026-W22 starts Monday 2026-05-25, later
        let weekPulse = makePulse(weekLabel: "2026-W22", label: nil)

        try await writer.writePulse(datePulse, to: corpus)
        try await writer.writePulse(weekPulse, to: corpus)

        let latest = try await writer.readLatestPulse(from: corpus)
        #expect(latest?.weekLabel == "2026-W22")
        #expect(latest?.label == nil)
    }

    // MARK: - parseLabelDate

    @Test("parseLabelDate parses YYYY-MM-DD format")
    func parseDateFormat() {
        let date = TelemetryWriter.parseLabelDate("2026-06-05")
        #expect(date != nil)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        #expect(fmt.string(from: date!) == "2026-06-05")
    }

    @Test("parseLabelDate parses YYYY-WNN format to Monday")
    func parseWeekFormat() {
        let date = TelemetryWriter.parseLabelDate("2026-W22")
        #expect(date != nil)

        // W22 of 2026 starts Monday 2026-05-25
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        #expect(fmt.string(from: date!) == "2026-05-25")
    }

    @Test("parseLabelDate returns nil for unrecognized format")
    func parseInvalidFormat() {
        #expect(TelemetryWriter.parseLabelDate("not-a-label") == nil)
        #expect(TelemetryWriter.parseLabelDate("2026") == nil)
        #expect(TelemetryWriter.parseLabelDate("") == nil)
    }

    @Test("parseLabelDate returns nil for invalid week number")
    func parseInvalidWeek() {
        #expect(TelemetryWriter.parseLabelDate("2026-W00") == nil)
        #expect(TelemetryWriter.parseLabelDate("2026-W54") == nil)
    }

    // MARK: - Round-trip with label

    @Test("writePulse with label round-trips through readLatestPulse")
    func roundTripWithLabel() async throws {
        let corpus = makeTempCorpusPath()
        let pulse = makePulse(weekLabel: "2026-W22", label: "2026-06-05")
        try await writer.writePulse(pulse, to: corpus)

        let latest = try await writer.readLatestPulse(from: corpus)
        #expect(latest == pulse)
        #expect(latest?.label == "2026-06-05")
        #expect(latest?.weekLabel == "2026-W22")
    }

    // MARK: - Backward-compatible JSON decoding

    @Test("InstitutionalPulse decodes JSON without label field")
    func decodeWithoutLabel() throws {
        let pulse = makePulse(weekLabel: "2026-W22", label: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Encode, then strip the label key if present
        let data = try encoder.encode(pulse)
        let decoded = try JSONDecoder.iso8601Decoder.decode(InstitutionalPulse.self, from: data)
        #expect(decoded.label == nil)
        #expect(decoded.weekLabel == "2026-W22")
    }

    @Test("InstitutionalPulse encodes label only when non-nil")
    func encodeOmitsNilLabel() throws {
        let pulse = makePulse(weekLabel: "2026-W22", label: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pulse)

        // silent: best-effort JSON parsing for test assertion
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] // silent: test validation
        #expect(json?["label"] == nil)
    }

    @Test("InstitutionalPulse encodes label when non-nil")
    func encodeIncludesLabel() throws {
        let pulse = makePulse(weekLabel: "2026-W22", label: "2026-06-05")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pulse)

        // silent: best-effort JSON parsing for test assertion
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] // silent: test validation
        #expect(json?["label"] as? String == "2026-06-05")
    }
}

// MARK: - Helpers

private extension JSONDecoder {
    static let iso8601Decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
}
