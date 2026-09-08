import Testing
import Foundation
@testable import QualityGateCore

/// Covers the I/O half of `CorpusRegistrationReminder.md` §10.
///
/// Asserted against a real corpus laid out as the live one is —
/// `telemetry/<projectID>/<date>/<HHMMSS>_{complexity,metadata,orientation}.json` — rather
/// than a mock, so "emitting" means what the gate actually writes.
@Suite("CorpusPresenceProbe")
struct CorpusPresenceProbeTests {

    // MARK: - Fixture

    /// Builds a throwaway corpus and returns its path. Caller deletes it.
    private func makeCorpus() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qg-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeTelemetry(
        in corpus: URL,
        project: String,
        date: String = "2026-08-07",
        bytes: Int
    ) throws {
        let dir = corpus
            .appendingPathComponent("telemetry")
            .appendingPathComponent(project)
            .appendingPathComponent(date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = String(repeating: "x", count: bytes)
        try payload.write(
            to: dir.appendingPathComponent("035322_metadata.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Emission

    @Test("A project with non-empty telemetry is emitting")
    func nonEmptyTelemetryIsEmitting() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writeTelemetry(in: corpus, project: "demo", bytes: 512)

        let presence = CorpusPresenceProbe.probe(corpusPath: corpus.path, projectID: "demo")
        #expect(presence == .emitting)
    }

    @Test("A project with no telemetry directory is absent")
    func missingProjectIsAbsent() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writeTelemetry(in: corpus, project: "someone-else", bytes: 512)

        let presence = CorpusPresenceProbe.probe(corpusPath: corpus.path, projectID: "demo")
        #expect(presence == .absent)
    }

    // MARK: - A directory is not emission

    @Test("A telemetry directory holding only empty files is absent")
    func emptyFilesAreNotEmission() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writeTelemetry(in: corpus, project: "demo", bytes: 0)

        let presence = CorpusPresenceProbe.probe(corpusPath: corpus.path, projectID: "demo")
        #expect(presence == .absent)
    }

    @Test("An empty telemetry directory is absent")
    func emptyDirectoryIsAbsent() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        let dir = corpus.appendingPathComponent("telemetry").appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let presence = CorpusPresenceProbe.probe(corpusPath: corpus.path, projectID: "demo")
        #expect(presence == .absent)
    }

    // MARK: - Unreadable

    @Test("A corpus that does not exist is unreadable, not absent")
    func missingCorpusIsUnreadable() throws {
        let missingPath = "/nonexistent-corpus-\(UUID().uuidString)"
        let presence = CorpusPresenceProbe.probe(corpusPath: missingPath, projectID: "demo")

        // Asserted as "not absent" as well as "is unreadable": conflating the two is the
        // defect this case exists to catch, and `.absent` would send a registered project
        // an onboarding instruction it does not need.
        #expect(presence != .absent)
        guard case .unreadable(let reason) = presence else {
            Issue.record("expected .unreadable, got \(presence)")
            return
        }
        #expect(reason.contains(missingPath))
    }

    // MARK: - Independence from the pulse

    @Test("A months-old pulse does not affect presence")
    func stalePulseDoesNotAffectPresence() throws {
        let corpus = try makeCorpus()
        defer { try? FileManager.default.removeItem(at: corpus) }
        try writeTelemetry(in: corpus, project: "demo", bytes: 512)

        // A pulse from long ago, exactly the condition that made pulse membership
        // unusable as a presence test.
        let pulseDir = corpus.appendingPathComponent("pulse").appendingPathComponent("2026-01-01")
        try FileManager.default.createDirectory(at: pulseDir, withIntermediateDirectories: true)
        try "{}".write(
            to: pulseDir.appendingPathComponent("PULSE_2026-01-01.json"),
            atomically: true,
            encoding: .utf8
        )

        let presence = CorpusPresenceProbe.probe(corpusPath: corpus.path, projectID: "demo")
        #expect(presence == .emitting)
    }
}
