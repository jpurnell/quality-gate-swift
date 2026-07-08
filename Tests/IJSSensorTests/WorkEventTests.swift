import Testing
import Foundation
@testable import IJSSensor

@Suite("WorkEvent")
struct WorkEventTests {

    static let referenceDate = Date(timeIntervalSince1970: 1_777_536_311)

    static func makeSample() -> WorkEvent {
        WorkEvent(
            date: referenceDate,
            commitSHA: "abc123",
            commitSubjects: ["feat: add thing", "fix: correct bug"],
            changelogDelta: "## Unreleased\n- added thing",
            sessionSummary: "Worked on the thing."
        )
    }

    @Test("Golden path: all fields populated")
    func goldenPath() {
        let event = Self.makeSample()
        #expect(event.commitSHA == "abc123")
        #expect(event.commitSubjects.count == 2)
        #expect(event.changelogDelta?.contains("added thing") == true)
        #expect(event.sessionSummary == "Worked on the thing.")
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let event = Self.makeSample()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(WorkEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("Minimal JSON (only date + commitSHA) decodes with sensible defaults")
    func minimalDecode() throws {
        let json = """
        {
          "date": "2026-04-28T14:30:22Z",
          "commitSHA": "deadbeef"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkEvent.self, from: Data(json.utf8))
        #expect(decoded.commitSHA == "deadbeef")
        #expect(decoded.commitSubjects.isEmpty)
        #expect(decoded.changelogDelta == nil)
        #expect(decoded.sessionSummary == nil)
    }

    @Test("Nil commitSHA is permitted")
    func nilCommitSHA() throws {
        let event = WorkEvent(
            date: Self.referenceDate,
            commitSHA: nil,
            commitSubjects: [],
            changelogDelta: nil,
            sessionSummary: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(WorkEvent.self, from: data)
        #expect(decoded.commitSHA == nil)
        #expect(decoded == event)
    }

    @Test("Sendable conformance")
    func sendable() {
        let event: any Sendable = Self.makeSample()
        #expect(event is WorkEvent)
    }
}
