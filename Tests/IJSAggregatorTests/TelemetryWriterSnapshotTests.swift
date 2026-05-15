import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor

@Suite("TelemetryWriter Snapshots")
struct TelemetryWriterSnapshotTests {

    private let writer = TelemetryWriter()

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeTempCorpusPath() -> CorpusPath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ijs-snapshot-test-\(UUID().uuidString)")
            .path
        return CorpusPath(basePath: base, projectID: "test-project")
    }

    private func makeSnapshot(date: String = "2026-04-28", scope: String = "test-project") -> DailySnapshot {
        DailySnapshot(
            date: makeDate(date),
            scope: scope,
            gateRuns: 10,
            passedRuns: 8,
            failedRuns: 2,
            overrides: 1,
            calibrations: 1,
            failuresByChecker: ["SafetyAuditor": 2],
            overridesByRiskTier: [.safety: 1]
        )
    }

    @Test("Write snapshot creates file at correct path")
    func writeCreatesFile() async throws {
        let corpus = makeTempCorpusPath()
        let snapshot = makeSnapshot()
        try await writer.writeSnapshot(snapshot, to: corpus)

        let expectedPath = corpus.snapshotPath(scope: snapshot.scope, date: snapshot.date)
        let resolved = URL(fileURLWithPath: expectedPath).standardized.resolvingSymlinksInPath()
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }

    @Test("Read snapshots round-trip")
    func readRoundTrip() async throws {
        let corpus = makeTempCorpusPath()
        let snapshot = makeSnapshot()
        try await writer.writeSnapshot(snapshot, to: corpus)

        let results = try await writer.readSnapshots(
            from: corpus,
            scope: "test-project",
            startDate: makeDate("2026-04-27"),
            endDate: makeDate("2026-04-29")
        )
        #expect(results.count == 1)
        #expect(results.first == snapshot)
    }

    @Test("Date range filtering only returns snapshots in range")
    func dateRangeFiltering() async throws {
        let corpus = makeTempCorpusPath()
        let snap1 = makeSnapshot(date: "2026-04-25")
        let snap2 = makeSnapshot(date: "2026-04-27")
        let snap3 = makeSnapshot(date: "2026-04-29")
        try await writer.writeSnapshot(snap1, to: corpus)
        try await writer.writeSnapshot(snap2, to: corpus)
        try await writer.writeSnapshot(snap3, to: corpus)

        let results = try await writer.readSnapshots(
            from: corpus,
            scope: "test-project",
            startDate: makeDate("2026-04-26"),
            endDate: makeDate("2026-04-28")
        )
        #expect(results.count == 1)
        #expect(results.first?.date == makeDate("2026-04-27"))
    }

    @Test("Scope isolation: different scopes in separate directories")
    func scopeIsolation() async throws {
        let corpus = makeTempCorpusPath()
        let projectSnap = makeSnapshot(scope: "my-project")
        let corpusSnap = makeSnapshot(scope: "corpus")
        try await writer.writeSnapshot(projectSnap, to: corpus)
        try await writer.writeSnapshot(corpusSnap, to: corpus)

        let projectResults = try await writer.readSnapshots(
            from: corpus,
            scope: "my-project",
            startDate: makeDate("2026-04-27"),
            endDate: makeDate("2026-04-29")
        )
        let corpusResults = try await writer.readSnapshots(
            from: corpus,
            scope: "corpus",
            startDate: makeDate("2026-04-27"),
            endDate: makeDate("2026-04-29")
        )
        #expect(projectResults.count == 1)
        #expect(corpusResults.count == 1)
        #expect(projectResults.first?.scope == "my-project")
        #expect(corpusResults.first?.scope == "corpus")
    }

    @Test("Overwrite: writing same date twice overwrites")
    func overwriteBehavior() async throws {
        let corpus = makeTempCorpusPath()
        let snap1 = DailySnapshot(
            date: makeDate("2026-04-28"),
            scope: "test-project",
            gateRuns: 5,
            passedRuns: 3,
            failedRuns: 2,
            overrides: 0,
            calibrations: 0,
            failuresByChecker: [:],
            overridesByRiskTier: [:]
        )
        let snap2 = DailySnapshot(
            date: makeDate("2026-04-28"),
            scope: "test-project",
            gateRuns: 10,
            passedRuns: 9,
            failedRuns: 1,
            overrides: 1,
            calibrations: 1,
            failuresByChecker: ["SafetyAuditor": 1],
            overridesByRiskTier: [.safety: 1]
        )
        try await writer.writeSnapshot(snap1, to: corpus)
        try await writer.writeSnapshot(snap2, to: corpus)

        let results = try await writer.readSnapshots(
            from: corpus,
            scope: "test-project",
            startDate: makeDate("2026-04-27"),
            endDate: makeDate("2026-04-29")
        )
        #expect(results.count == 1)
        #expect(results.first?.gateRuns == 10)
    }

    @Test("Empty scope directory returns empty array")
    func emptyScopeDirectory() async throws {
        let corpus = makeTempCorpusPath()
        let results = try await writer.readSnapshots(
            from: corpus,
            scope: "nonexistent",
            startDate: makeDate("2026-04-01"),
            endDate: makeDate("2026-04-30")
        )
        #expect(results.isEmpty)
    }

    @Test("Path sanitization prevents directory traversal")
    func pathSanitization() async throws {
        let corpus = makeTempCorpusPath()
        let maliciousSnapshot = DailySnapshot(
            date: makeDate("2026-04-28"),
            scope: "../../../etc",
            gateRuns: 1,
            passedRuns: 1,
            failedRuns: 0,
            overrides: 0,
            calibrations: 0,
            failuresByChecker: [:],
            overridesByRiskTier: [:]
        )
        await #expect(throws: IJSError.self) {
            try await writer.writeSnapshot(maliciousSnapshot, to: corpus)
        }
    }
}
