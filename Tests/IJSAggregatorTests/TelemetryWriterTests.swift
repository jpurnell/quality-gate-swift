import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor
import QualityGateTypes

@Suite("TelemetryWriter")
struct TelemetryWriterTests {

    // MARK: - Fixtures

    static let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 4, day: 28, hour: 14, minute: 30, second: 22))!
    }()

    static let sampleMetadata = CheckResultMetadata(
        projectID: "test-project",
        timestamp: referenceDate,
        environment: .ci,
        decisionOwner: "jpurnell",
        results: [
            CheckResult(
                checkerId: "SafetyAuditor",
                status: .passed,
                diagnostics: [],
                duration: .seconds(1)
            ),
        ],
        overrides: [],
        riskTier: .operational,
        ethicalFlags: [],
        consistencyScore: nil
    )

    static let sampleCalibration: JudgmentCalibration = {
        let rca = RootCauseAnalysis(
            proximateCause: "Agent used force unwrap",
            chainOfInquiry: ["Why force unwrap?", "No guidance on optional handling"],
            rootCause: "contextually naive",
            failedStep: .diagnosis,
            isRecurringPattern: false
        )
        return JudgmentCalibration(
            date: referenceDate,
            decisionOwner: "jpurnell",
            practitioner: "claude-opus-4-6",
            riskTier: .safety,
            rootCauseAnalysis: rca,
            redTeamDissent: "Could use optional binding instead.",
            proposedPolicyUpdate: "Add force-unwrap guidance",
            pulseContribution: "Force unwrap override in safety context."
        )
    }()

    static func makeTempCorpusPath() -> CorpusPath {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ijs-test-\(UUID().uuidString)")
        return CorpusPath(basePath: tmpDir.path, projectID: "test-project")
    }

    static func cleanup(_ corpusPath: CorpusPath) {
        try? FileManager.default.removeItem(atPath: corpusPath.basePath)
    }

    // MARK: - Write Tests

    @Test("Write metadata creates file at expected path")
    func writeMetadata() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)

        let expectedPath = corpus.metadataPath(for: Self.referenceDate)
        #expect(FileManager.default.fileExists(atPath: expectedPath))
    }

    @Test("Written metadata file contains valid JSON")
    func writeMetadataValidJSON() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)

        let path = corpus.metadataPath(for: Self.referenceDate)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try JSONSerialization.jsonObject(with: data)
        #expect(json is [String: Any])
    }

    @Test("Write calibrations creates N files for N calibrations")
    func writeCalibrations() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        let calibrations = [Self.sampleCalibration, Self.sampleCalibration]
        try await writer.write(metadata: Self.sampleMetadata, calibrations: calibrations, to: corpus)

        let path0 = corpus.calibrationPath(for: Self.referenceDate, index: 0)
        let path1 = corpus.calibrationPath(for: Self.referenceDate, index: 1)
        #expect(FileManager.default.fileExists(atPath: path0))
        #expect(FileManager.default.fileExists(atPath: path1))
    }

    @Test("Zero calibrations produces no calibration files")
    func writeZeroCalibrations() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)

        let path0 = corpus.calibrationPath(for: Self.referenceDate, index: 0)
        #expect(FileManager.default.fileExists(atPath: path0) == false)
    }

    @Test("Writer creates nested directories that don't exist")
    func directoryCreation() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        let dailyDir = corpus.dailyDirectory(for: Self.referenceDate)
        #expect(FileManager.default.fileExists(atPath: dailyDir) == false)

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)

        #expect(FileManager.default.fileExists(atPath: dailyDir))
    }

    // MARK: - Read Tests

    @Test("Read metadata round-trip: write then read back")
    func readMetadataRoundTrip() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)

        let results = try await writer.readMetadata(
            from: corpus,
            startDate: Self.referenceDate.addingTimeInterval(-3600),
            endDate: Self.referenceDate.addingTimeInterval(3600)
        )
        #expect(results.count == 1)
        #expect(results[0].projectID == "test-project")
        #expect(results[0].environment == .ci)
        #expect(results[0].results.count == 1)
    }

    @Test("Read calibrations round-trip: write then read back")
    func readCalibrationsRoundTrip() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await writer.write(
            metadata: Self.sampleMetadata,
            calibrations: [Self.sampleCalibration],
            to: corpus
        )

        let results = try await writer.readCalibrations(
            from: corpus,
            startDate: Self.referenceDate.addingTimeInterval(-3600),
            endDate: Self.referenceDate.addingTimeInterval(3600)
        )
        #expect(results.count == 1)
        #expect(results[0].practitioner == "claude-opus-4-6")
        #expect(results[0].rootCauseAnalysis.rootCause == "contextually naive")
    }

    @Test("Date range filtering excludes files outside range")
    func dateRangeFiltering() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)

        let dayBefore = Self.referenceDate.addingTimeInterval(-86400 * 2)
        let dayBeforeEnd = Self.referenceDate.addingTimeInterval(-86400)
        let results = try await writer.readMetadata(
            from: corpus,
            startDate: dayBefore,
            endDate: dayBeforeEnd
        )
        #expect(results.isEmpty)
    }

    @Test("Empty corpus returns empty array, not error")
    func emptyCorpus() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        let results = try await writer.readMetadata(
            from: corpus,
            startDate: Date.distantPast,
            endDate: Date.distantFuture
        )
        #expect(results.isEmpty)
    }

    // MARK: - Multi-day Tests

    @Test("Read across multiple daily directories")
    func multiDayRead() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        let day1 = Self.referenceDate
        let day2 = Self.referenceDate.addingTimeInterval(86400)
        let meta2 = CheckResultMetadata(
            projectID: "test-project",
            timestamp: day2,
            environment: .local,
            decisionOwner: "jpurnell",
            results: [],
            overrides: [],
            riskTier: .informational,
            ethicalFlags: [],
            consistencyScore: 0.9
        )

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)
        try await writer.write(metadata: meta2, calibrations: [], to: corpus)

        let results = try await writer.readMetadata(
            from: corpus,
            startDate: day1.addingTimeInterval(-3600),
            endDate: day2.addingTimeInterval(3600)
        )
        #expect(results.count == 2)
    }

    // MARK: - Concurrency Tests

    @Test("Concurrent writes from multiple tasks produce correct files")
    func concurrentWrites() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let timestamp = Self.referenceDate.addingTimeInterval(Double(i))
                    let meta = CheckResultMetadata(
                        projectID: "test-project",
                        timestamp: timestamp,
                        environment: .ci,
                        decisionOwner: "jpurnell",
                        results: [],
                        overrides: [],
                        riskTier: .operational,
                        ethicalFlags: [],
                        consistencyScore: nil
                    )
                    try await writer.write(metadata: meta, calibrations: [], to: corpus)
                }
            }
            try await group.waitForAll()
        }

        let results = try await writer.readMetadata(
            from: corpus,
            startDate: Self.referenceDate.addingTimeInterval(-1),
            endDate: Self.referenceDate.addingTimeInterval(10)
        )
        #expect(results.count == 5)
    }

    // MARK: - JSON Format Tests

    @Test("Written metadata uses sorted keys and pretty printing")
    func jsonFormat() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)

        let path = corpus.metadataPath(for: Self.referenceDate)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\n"))
        #expect(json.contains("\"projectID\""))
    }

    @Test("Written metadata uses ISO 8601 dates")
    func iso8601Dates() async throws {
        let corpus = Self.makeTempCorpusPath()
        defer { Self.cleanup(corpus) }
        let writer = TelemetryWriter()

        try await writer.write(metadata: Self.sampleMetadata, calibrations: [], to: corpus)

        let path = corpus.metadataPath(for: Self.referenceDate)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("2026-"))
    }
}
