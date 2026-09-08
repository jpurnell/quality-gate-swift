import Testing
import Foundation
@testable import QualityGateCore

/// Covers the decision table in `PulseStalenessDetection.md` §10.
///
/// Age is measured from the pulse file's modification time, not from its directory name,
/// so every fixture sets that time explicitly. `now` is injected too — no test reads the
/// clock, which is what lets the real June outage be pinned to real dates.
@Suite("PulseFreshnessProbe")
struct PulseFreshnessProbeTests {

    // MARK: - Fixture

    private func makeCorpus() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qg-pulse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func at(_ iso: String) throws -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return try #require(fmt.date(from: iso))
    }

    /// Writes `pulse/<date>/PULSE_<date>.json` and stamps it with `written`, mirroring the
    /// live corpus where generation happens at 08:01, not at midnight.
    private func writePulse(in corpus: URL, date: String, written: Date) throws {
        let dir = corpus.appendingPathComponent("pulse").appendingPathComponent(date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("PULSE_\(date).json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
    }

    // MARK: - Fresh

    @Test("A pulse generated this morning is current")
    func todayIsCurrent() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writePulse(in: corpus, date: "2026-08-07", written: try at("2026-08-07 08:01"))

        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-08-07 19:00"), staleAfterHours: 36)
        #expect(f == .current(ageInHours: 10))
    }

    @Test("A full day between runs is normal and stays silent")
    func normalDailyCycleIsSilent() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writePulse(in: corpus, date: "2026-08-06", written: try at("2026-08-06 08:01"))

        // Just before the next morning's run: 24 hours old, entirely healthy.
        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-08-07 08:00"), staleAfterHours: 36)
        #expect(f == .current(ageInHours: 23))
    }

    @Test("A late start on a slow morning still stays silent")
    func lateWakeIsTolerated() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writePulse(in: corpus, date: "2026-08-06", written: try at("2026-08-06 08:01"))

        // The machine wakes at 14:00 the next day: 30 hours. This is the case that a
        // 26-hour threshold would have reported as an outage.
        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-08-07 14:00"), staleAfterHours: 36)
        #expect(f == .current(ageInHours: 29))
    }

    // MARK: - A genuinely missed day

    @Test("A missed day is reported once past the threshold")
    func missedDayIsReported() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writePulse(in: corpus, date: "2026-08-05", written: try at("2026-08-05 08:01"))

        // Two mornings have passed with no pulse: 38h59m, which floors to 38.
        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-08-06 23:00"), staleAfterHours: 36)
        #expect(f == .stale(ageInHours: 38, newest: "2026-08-05"))
    }

    @Test("The real June outage is caught, and names the last good pulse")
    func realOutageIsCaught() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        // The live corpus's history: daily pulses to 06-22, then nothing until 06-30.
        for d in ["2026-06-20", "2026-06-21", "2026-06-22"] {
            try writePulse(in: corpus, date: d, written: try at("\(d) 08:01"))
        }

        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-06-29 08:01"), staleAfterHours: 36)
        #expect(f == .stale(ageInHours: 168, newest: "2026-06-22"))
    }

    // MARK: - Edges

    @Test("A corpus with no pulses at all is distinguished from a stale one")
    func noPulseEver() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try FileManager.default.createDirectory(
            at: corpus.appendingPathComponent("pulse"), withIntermediateDirectories: true)

        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-08-07 19:00"), staleAfterHours: 36)
        #expect(f == .noPulseEver)
    }

    @Test("An unreadable corpus reports itself rather than claiming staleness")
    func unreadableCorpus() throws {
        let f = PulseFreshnessProbe.probe(
            corpusPath: "/nonexistent-\(UUID().uuidString)",
            now: try at("2026-08-07 19:00"), staleAfterHours: 36)
        guard case .unreadable = f else {
            Issue.record("expected .unreadable, got \(f)")
            return
        }
        #expect(f != .noPulseEver)
    }

    @Test("A threshold of 0 disables the check entirely")
    func zeroDisables() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writePulse(in: corpus, date: "2026-01-01", written: try at("2026-01-01 08:01"))

        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-08-07 19:00"), staleAfterHours: 0)
        // Asserted as "not stale" as well: a 219-day-old pulse with the check disabled is
        // exactly the case where a silent regression would go unnoticed.
        #expect(f == .current(ageInHours: 5242))   // 218 days + 10h59m
    }

    @Test("Week-labelled pulse directories are ignored; only dated ones count")
    func mixedNamingIgnoresWeekLabels() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writePulse(in: corpus, date: "2026-08-07", written: try at("2026-08-07 08:01"))
        // The corpus also holds PULSE_2026-W26.json from an older scheme. A lexical sort
        // ranks "2026-W26" above every dated name, which would make it look newest.
        let wk = corpus.appendingPathComponent("pulse").appendingPathComponent("2026-W26")
        try FileManager.default.createDirectory(at: wk, withIntermediateDirectories: true)
        try "{}".write(to: wk.appendingPathComponent("PULSE_2026-W26.json"),
                       atomically: true, encoding: .utf8)

        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-08-07 19:00"), staleAfterHours: 36)
        #expect(f == .current(ageInHours: 10))
    }

    // MARK: - Age comes from the file, not the directory name

    @Test("Age is measured from the write time, not from midnight of the directory date")
    func ageUsesFileTimeNotDirectoryName() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writePulse(in: corpus, date: "2026-08-07", written: try at("2026-08-07 08:01"))

        // Measured from the directory name this would be 19 hours; from the file, 10.
        // At a 36-hour threshold that 8-hour error is the difference between a false
        // report and a correct silence.
        let f = PulseFreshnessProbe.probe(
            corpusPath: corpus.path, now: try at("2026-08-07 19:00"), staleAfterHours: 36)
        #expect(f == .current(ageInHours: 10))
    }
}
