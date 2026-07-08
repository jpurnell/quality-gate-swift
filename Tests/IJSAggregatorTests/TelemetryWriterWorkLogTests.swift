import Testing
import Foundation
@testable import IJSAggregator
import IJSSensor

@Suite("TelemetryWriter WorkLog")
struct TelemetryWriterWorkLogTests {

    private let writer = TelemetryWriter()

    private func makeTempCorpusPath() -> CorpusPath {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ijs-worklog-test-\(UUID().uuidString)")
            .path
        return CorpusPath(basePath: base, projectID: "test-project")
    }

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    @Test("readWorkLog on missing file returns empty array")
    func readMissingReturnsEmpty() async throws {
        let corpus = makeTempCorpusPath()
        let events = try await writer.readWorkLog(from: corpus)
        #expect(events.isEmpty)
    }

    @Test("writeWorkEvent then readWorkLog round-trips")
    func writeReadRoundTrip() async throws {
        let corpus = makeTempCorpusPath()
        let event = WorkEvent(
            date: makeDate("2026-04-28T14:30:22"),
            commitSHA: "abc123",
            commitSubjects: ["feat: thing"],
            changelogDelta: nil,
            sessionSummary: nil
        )
        try await writer.writeWorkEvent(event, to: corpus)
        let events = try await writer.readWorkLog(from: corpus)
        #expect(events.count == 1)
        #expect(events.first == event)
    }

    @Test("Idempotent: same day+SHA written twice yields ONE entry (replaces)")
    func idempotentSameDaySHA() async throws {
        let corpus = makeTempCorpusPath()
        let first = WorkEvent(
            date: makeDate("2026-04-28T09:00:00"),
            commitSHA: "abc123",
            commitSubjects: ["feat: initial"],
            changelogDelta: nil,
            sessionSummary: nil
        )
        // Same calendar day, same SHA, but different content/time — should REPLACE.
        let second = WorkEvent(
            date: makeDate("2026-04-28T17:00:00"),
            commitSHA: "abc123",
            commitSubjects: ["feat: initial", "fix: follow-up"],
            changelogDelta: "## Unreleased",
            sessionSummary: "Later run."
        )
        try await writer.writeWorkEvent(first, to: corpus)
        try await writer.writeWorkEvent(second, to: corpus)

        let events = try await writer.readWorkLog(from: corpus)
        #expect(events.count == 1)
        #expect(events.first?.commitSubjects.count == 2)
        #expect(events.first?.sessionSummary == "Later run.")
    }

    @Test("Different SHA appends")
    func differentSHAAppends() async throws {
        let corpus = makeTempCorpusPath()
        let first = WorkEvent(
            date: makeDate("2026-04-28T09:00:00"),
            commitSHA: "aaa",
            commitSubjects: ["a"],
            changelogDelta: nil,
            sessionSummary: nil
        )
        let second = WorkEvent(
            date: makeDate("2026-04-28T10:00:00"),
            commitSHA: "bbb",
            commitSubjects: ["b"],
            changelogDelta: nil,
            sessionSummary: nil
        )
        try await writer.writeWorkEvent(first, to: corpus)
        try await writer.writeWorkEvent(second, to: corpus)

        let events = try await writer.readWorkLog(from: corpus)
        #expect(events.count == 2)
    }

    @Test("Different calendar day with same SHA appends")
    func differentDaySameSHAAppends() async throws {
        let corpus = makeTempCorpusPath()
        let first = WorkEvent(
            date: makeDate("2026-04-28T09:00:00"),
            commitSHA: "abc",
            commitSubjects: ["a"],
            changelogDelta: nil,
            sessionSummary: nil
        )
        let second = WorkEvent(
            date: makeDate("2026-04-29T09:00:00"),
            commitSHA: "abc",
            commitSubjects: ["a"],
            changelogDelta: nil,
            sessionSummary: nil
        )
        try await writer.writeWorkEvent(first, to: corpus)
        try await writer.writeWorkEvent(second, to: corpus)

        let events = try await writer.readWorkLog(from: corpus)
        #expect(events.count == 2)
    }

    @Test("Log is kept sorted by date")
    func keptSorted() async throws {
        let corpus = makeTempCorpusPath()
        let later = WorkEvent(
            date: makeDate("2026-04-29T09:00:00"),
            commitSHA: "later",
            commitSubjects: [],
            changelogDelta: nil,
            sessionSummary: nil
        )
        let earlier = WorkEvent(
            date: makeDate("2026-04-27T09:00:00"),
            commitSHA: "earlier",
            commitSubjects: [],
            changelogDelta: nil,
            sessionSummary: nil
        )
        // Write out of order.
        try await writer.writeWorkEvent(later, to: corpus)
        try await writer.writeWorkEvent(earlier, to: corpus)

        let events = try await writer.readWorkLog(from: corpus)
        #expect(events.count == 2)
        #expect(events.first?.commitSHA == "earlier")
        #expect(events.last?.commitSHA == "later")
    }
}
