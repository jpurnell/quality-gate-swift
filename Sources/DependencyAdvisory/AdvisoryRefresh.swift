import Foundation
import QualityGateCore
import QualityGateLogging

/// Why a refresh produced no snapshot.
public enum AdvisoryRefreshError: Error, Sendable, Equatable, LocalizedError {
    /// The id list was empty. A database with nothing in it is a failed download.
    case emptyList
    /// A line of the id list was not `timestamp,id`, or the id was not an identifier.
    case malformedList(line: String)
    /// The list named more records than a snapshot is allowed to hold.
    case tooManyRecords(Int)
    /// The record returned for an id was not that record, or not a record.
    case recordMismatch(requested: String)
    /// The new snapshot holds fewer records than the one it would replace.
    case wouldShrink(from: Int, to: Int)

    /// The reason, in words.
    public var errorDescription: String? {
        switch self {
        case .emptyList:
            return "the advisory id list was empty — a database with nothing in it is a failed download"
        case .malformedList(let line):
            return "the advisory id list has a line that is not `timestamp,id`: \(line.prefix(120))"
        case .tooManyRecords(let count):
            return "the advisory id list names \(count) records, over the \(AdvisoryRefresh.maximumRecords) a snapshot may hold"
        case .recordMismatch(let requested):
            return "the record returned for \(requested) is not \(requested)"
        case .wouldShrink(let from, let to):
            return "the refreshed snapshot holds \(to) records and the one it replaces holds \(from). Advisories are "
                + "withdrawn individually, not deleted, so a database that lost records is a failed download. "
                + "Pass --allow-shrink if the loss is real."
        }
    }
}

/// Downloads the OSV `SwiftURL` advisories and builds a snapshot from them.
///
/// The only writer of a snapshot, and deliberately not a checker: it reaches the network and it
/// produces a file, and checkers do neither. It runs in the gate's release process — which is
/// how the bundled snapshot is renewed — and, for a repository that commits its own, wherever
/// that repository schedules it.
///
/// ## Why the id list and the record endpoint, not the ZIP export
///
/// OSV publishes the ecosystem as `SwiftURL/all.zip`. Reading it needs an inflater, which this
/// package does not have and would need a dependency or a subprocess to get. The same records
/// are served one at a time by `GET /v1/vulns/{id}` — compared on 2026-10-06 and identical — and
/// `SwiftURL/modified_id.csv` lists the ids. That is 65 small requests instead of one large one,
/// each of them bounded, and no archive is ever unpacked.
public enum AdvisoryRefresh {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DependencyAdvisory")

    /// The most records a snapshot may hold. The ecosystem had 64 on 2026-10-06.
    static let maximumRecords = 5_000

    /// The deadline for each request.
    static let timeoutSeconds: Double = 15

    /// The ceiling on the id list's size.
    static let maximumListBytes = 4 * 1024 * 1024

    /// The ceiling on one record's size. The largest on 2026-10-06 was under 20 KB.
    static let maximumRecordBytes = 2 * 1024 * 1024

    /// The export's id list: `timestamp,id` per line, newest modification first.
    static let listAddress = "https://osv-vulnerabilities.storage.googleapis.com/SwiftURL/modified_id.csv"

    /// Where one record is read from.
    static func recordAddress(for id: String) -> String { "https://api.osv.dev/v1/vulns/\(id)" }

    /// What a refresh found.
    public struct Report: Sendable {
        let snapshot: AdvisorySnapshot
        let previous: AdvisorySnapshot?
        /// Ids in the new snapshot and not in the previous one.
        let added: [String]
        /// Ids in the previous snapshot and not in the new one.
        let removed: [String]
        /// Ids withdrawn in the new snapshot that were live in the previous one.
        let newlyWithdrawn: [String]

        /// The snapshot file's contents.
        public func encodedSnapshot() throws -> Data { try snapshot.encoded() }

        /// What changed, for a person to read: a header line, then one line per advisory that
        /// arrived, left, or was withdrawn.
        public var summaryLines: [String] {
            let before = previous.map { " (previous: \($0.recordCount) records fetched \($0.fetched))" } ?? ""
            var lines = ["Advisory snapshot: \(snapshot.recordCount) records fetched \(snapshot.fetched)\(before)."]
            let byID = Dictionary(snapshot.advisories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in added {
                guard let advisory = byID[id] else { continue }
                let qualifiers = (advisory.aliases + [advisory.severityLabel ?? "no severity recorded"]).joined(separator: ", ")
                lines.append("  + \(id) (\(qualifiers)) \(advisory.summary)")
            }
            for id in removed { lines.append("  - \(id) is no longer in the database") }
            for id in newlyWithdrawn { lines.append("  ~ \(id) withdrawn \(byID[id]?.withdrawn ?? "")") }
            return lines
        }
    }

    /// Fetches the current advisories over the network and compares them with `previousData`.
    ///
    /// - Parameters:
    ///   - previousData: The snapshot file being replaced, if there is one. Unreadable data is
    ///     treated as no previous snapshot.
    ///   - allowShrink: Accept a result with fewer records than the previous snapshot.
    ///   - now: The instant whose UTC date is recorded as `fetched`.
    /// - Returns: The new snapshot and what changed.
    /// - Throws: ``AdvisoryRefreshError``, or the transport's error when OSV cannot be reached.
    public static func refresh(previousData: Data?, allowShrink: Bool, now: Date) async throws -> Report {
        var previous: AdvisorySnapshot?
        if let previousData, case .success(let snapshot) = AdvisorySnapshot.decode(previousData) {
            previous = snapshot
        }
        return try await fetch(
            transport: URLSessionAdvisoryTransport(),
            today: AdvisoryDate(utcDateOf: now).text,
            previous: previous ?? bundledSnapshot(),
            allowShrink: allowShrink)
    }

    /// The snapshot shipped with this gate, as a baseline when no file is being replaced.
    private static func bundledSnapshot() -> AdvisorySnapshot? {
        guard case .success(let snapshot)? = AdvisorySnapshotStore.bundled()?.decoded else { return nil }
        return snapshot
    }

    /// Reads the id list, then each record, through `transport`.
    static func fetch(
        transport: any AdvisoryTransport, today: String, previous: AdvisorySnapshot?, allowShrink: Bool
    ) async throws -> Report {
        let list = try await transport.send(AdvisoryRequest(
            url: try AdvisoryRequest.url(listAddress), body: nil, timeoutSeconds: timeoutSeconds,
            maximumResponseBytes: maximumListBytes))
        let ids = try parseList(list)

        var records: [JSONValue] = []
        records.reserveCapacity(ids.count)
        for id in ids {
            let data = try await transport.send(AdvisoryRequest(
                url: try AdvisoryRequest.url(recordAddress(for: id)), body: nil, timeoutSeconds: timeoutSeconds,
                maximumResponseBytes: maximumRecordBytes))
            records.append(try record(data, requested: id))
        }

        let snapshot = AdvisorySnapshot.make(records: records, fetched: today)
        if let previous, snapshot.recordCount < previous.recordCount, !allowShrink {
            throw AdvisoryRefreshError.wouldShrink(from: previous.recordCount, to: snapshot.recordCount)
        }
        return report(snapshot, previous: previous)
    }

    /// The ids in a `timestamp,id` list, each once, in list order.
    static func parseList(_ data: Data) throws -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        var ids: [String] = []
        var seen: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 2, let id = fields.last.map(String.init), isIdentifier(id) else {
                throw AdvisoryRefreshError.malformedList(line: String(line))
            }
            if seen.insert(id).inserted { ids.append(id) }
        }
        guard !ids.isEmpty else { throw AdvisoryRefreshError.emptyList }
        guard ids.count <= maximumRecords else { throw AdvisoryRefreshError.tooManyRecords(ids.count) }
        return ids
    }

    /// An advisory id is letters, digits and hyphens — which is also what makes it safe to place
    /// in a URL path. Anything else in the list is not an id.
    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Decodes one record and checks it is the one that was asked for.
    private static func record(_ data: Data, requested id: String) throws -> JSONValue {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            logger.warning("the record for \(id, privacy: .public) was not JSON: \(error.localizedDescription, privacy: .public)")
            throw AdvisoryRefreshError.recordMismatch(requested: id)
        }
        guard value["id"]?.stringValue == id else { throw AdvisoryRefreshError.recordMismatch(requested: id) }
        return value
    }

    private static func report(_ snapshot: AdvisorySnapshot, previous: AdvisorySnapshot?) -> Report {
        let now = Set(snapshot.advisories.map(\.id))
        let before = Set(previous?.advisories.map(\.id) ?? [])
        let liveBefore = Set(previous?.advisories.filter { $0.withdrawn == nil }.map(\.id) ?? [])
        return Report(
            snapshot: snapshot,
            previous: previous,
            added: previous == nil ? [] : now.subtracting(before).sorted(),
            removed: before.subtracting(now).sorted(),
            newlyWithdrawn: snapshot.advisories.filter { $0.withdrawn != nil && liveBefore.contains($0.id) }.map(\.id))
    }
}
