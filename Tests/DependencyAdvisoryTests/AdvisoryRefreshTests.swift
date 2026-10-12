import Foundation
import Testing
import QualityGateCore
@testable import DependencyAdvisory

/// `quality-gate advisories refresh`: the only thing that writes a snapshot.
///
/// The transport is injected and answers from the files recorded on 2026-10-06, so the refresh
/// is exercised end to end — list, records, snapshot, report — without a connection.
@Suite("advisories refresh")
struct AdvisoryRefreshTests {

    /// The recorded id list, cut down to the ids whose records were recorded.
    private static func recordedList() throws -> String {
        let have = Set(try RecordedOSV.records().compactMap { $0["id"]?.stringValue })
        let text = try #require(String(data: try RecordedOSV.data("modified_id.csv"), encoding: .utf8))
        return text.split(whereSeparator: \.isNewline).filter { line in
            line.split(separator: ",").last.map { have.contains(String($0)) } ?? false
        }.joined(separator: "\n") + "\n"
    }

    /// Serves the list and each recorded record from disk.
    private static func recordedTransport(list: String? = nil) throws -> RecordingTransport {
        let list = try list ?? recordedList()
        return RecordingTransport { request in
            if request.url.absoluteString == AdvisoryRefresh.listAddress { return Data(list.utf8) }
            let id = request.url.lastPathComponent
            return try RecordedOSV.data("records/\(id).json")
        }
    }

    @Test("a refresh reads the id list, then each record, and writes a snapshot that is true of them")
    func refresh() async throws {
        let transport = try Self.recordedTransport()

        let report = try await AdvisoryRefresh.fetch(
            transport: transport, today: "2026-10-06", previous: nil, allowShrink: false)

        #expect(report.snapshot == (try RecordedOSV.snapshot()))
        #expect(report.snapshot.fetched == "2026-10-06")
        #expect(report.snapshot.recordCount == 20)
        #expect(report.snapshot.newestModified == "2026-09-10T03:51:09.377604394Z")
        #expect(report.snapshot.sourceRef == "https://osv-vulnerabilities.storage.googleapis.com/SwiftURL/modified_id.csv "
            + "+ https://api.osv.dev/v1/vulns/{id}")
        // What it writes is what `decode` accepts: the header verifies against the records.
        #expect(try AdvisorySnapshot.decode(report.snapshot.encoded()).get() == report.snapshot)

        let requests = await transport.requests
        #expect(requests.count == 21)
        #expect(requests.first?.url.absoluteString
            == "https://osv-vulnerabilities.storage.googleapis.com/SwiftURL/modified_id.csv")
        #expect(requests.dropFirst().allSatisfy { $0.url.absoluteString.hasPrefix("https://api.osv.dev/v1/vulns/GHSA-") })
        // Every call is bounded.
        #expect(requests.allSatisfy { $0.timeoutSeconds == 15 && $0.body == nil })
        #expect(requests.first?.maximumResponseBytes == 4 * 1024 * 1024)
        #expect(requests.dropFirst().allSatisfy { $0.maximumResponseBytes == 2 * 1024 * 1024 })
    }

    @Test("the report says what arrived and what was withdrawn since the previous snapshot")
    func reportsWhatChanged() async throws {
        // The previous snapshot lacks one record, and holds another before it was withdrawn.
        let previousRecords = try RecordedOSV.records().compactMap { record -> JSONValue? in
            guard case .object(var members) = record, let id = record["id"]?.stringValue else { return nil }
            if id == "GHSA-rj37-6j9x-74q6" { return nil }
            if id == "GHSA-gpgx-whwh-r297" { members["withdrawn"] = nil }
            return .object(members)
        }
        let previous = AdvisorySnapshot.make(records: previousRecords, fetched: "2026-06-11")

        let report = try await AdvisoryRefresh.fetch(
            transport: try Self.recordedTransport(), today: "2026-10-06", previous: previous, allowShrink: false)

        #expect(report.added == ["GHSA-rj37-6j9x-74q6"])
        #expect(report.removed.isEmpty)
        #expect(report.newlyWithdrawn == ["GHSA-gpgx-whwh-r297"])
        #expect(report.summaryLines == [
            "Advisory snapshot: 20 records fetched 2026-10-06 (previous: 19 records fetched 2026-06-11).",
            "  + GHSA-rj37-6j9x-74q6 (CVE-2026-28980, HIGH) SwiftNIO NIOHTTP1:  HTTPDecoder accepts unbounded HTTP/1 header blocks, enabling remote DoS",
            "  ~ GHSA-gpgx-whwh-r297 withdrawn 2023-06-19T16:50:23Z",
        ])
    }

    /// Advisories are withdrawn individually and marked as such. A database that lost records
    /// overnight is a failed download.
    @Test("a refresh that returns fewer records than the snapshot it replaces is refused")
    func refusesToShrink() async throws {
        let extra = try JSONDecoder().decode(JSONValue.self, from: Data(AdvisoryFixture.zipTraversal
            .replacingOccurrences(of: "GHSA-g454-wj9r-jpg4", with: "GHSA-zzzz-zzzz-zzzz").utf8))
        let previous = AdvisorySnapshot.make(records: try RecordedOSV.records() + [extra], fetched: "2026-10-01")

        await #expect(throws: AdvisoryRefreshError.wouldShrink(from: 21, to: 20)) {
            _ = try await AdvisoryRefresh.fetch(
                transport: try Self.recordedTransport(), today: "2026-10-06", previous: previous, allowShrink: false)
        }

        let allowed = try await AdvisoryRefresh.fetch(
            transport: try Self.recordedTransport(), today: "2026-10-06", previous: previous, allowShrink: true)
        #expect(allowed.snapshot.recordCount == 20)
        #expect(allowed.removed == ["GHSA-zzzz-zzzz-zzzz"])
    }

    @Test("an id list that is empty, malformed or implausibly long is a failed download, not a snapshot", arguments: [
        ("", AdvisoryRefreshError.emptyList),
        ("<html>404</html>\n", AdvisoryRefreshError.malformedList(line: "<html>404</html>")),
        ("2026-10-05T23:00:05Z,../../etc/passwd\n", AdvisoryRefreshError.malformedList(line: "2026-10-05T23:00:05Z,../../etc/passwd")),
    ])
    func badList(list: String, expected: AdvisoryRefreshError) async throws {
        await #expect(throws: expected) {
            _ = try await AdvisoryRefresh.fetch(
                transport: try Self.recordedTransport(list: list), today: "2026-10-06", previous: nil, allowShrink: false)
        }
    }

    @Test("more ids than the cap is refused before any record is fetched")
    func tooManyIDs() async throws {
        let list = (0..<(AdvisoryRefresh.maximumRecords + 1)).map { "2026-10-05T23:00:05Z,GHSA-\($0)" }.joined(separator: "\n")
        let transport = try Self.recordedTransport(list: list)
        await #expect(throws: AdvisoryRefreshError.tooManyRecords(AdvisoryRefresh.maximumRecords + 1)) {
            _ = try await AdvisoryRefresh.fetch(transport: transport, today: "2026-10-06", previous: nil, allowShrink: false)
        }
        #expect(await transport.requests.count == 1)
        #expect(AdvisoryRefresh.maximumRecords == 5_000)
    }

    @Test("a record that is not the one asked for is refused")
    func wrongRecord() async throws {
        let transport = RecordingTransport { request in
            if request.url.absoluteString == AdvisoryRefresh.listAddress { return Data("2026-10-05T23:00:05Z,GHSA-rj37-6j9x-74q6\n".utf8) }
            return try RecordedOSV.data("records/GHSA-g454-wj9r-jpg4.json")
        }
        await #expect(throws: AdvisoryRefreshError.recordMismatch(requested: "GHSA-rj37-6j9x-74q6")) {
            _ = try await AdvisoryRefresh.fetch(transport: transport, today: "2026-10-06", previous: nil, allowShrink: false)
        }
    }

    @Test("a transport failure part-way leaves no snapshot")
    func transportFailure() async throws {
        let list = try Self.recordedList()
        let transport = RecordingTransport { request in
            if request.url.absoluteString == AdvisoryRefresh.listAddress { return Data(list.utf8) }
            throw OfflineError()
        }
        await #expect(throws: OfflineError.self) {
            _ = try await AdvisoryRefresh.fetch(transport: transport, today: "2026-10-06", previous: nil, allowShrink: false)
        }
    }
}
