import Crypto
import Foundation
import QualityGateCore
import QualityGateLogging

/// What is known about published Swift advisories, as of one day.
///
/// ## Why a file and not a request
///
/// *"swift-nio before 2.100.0 accepts unbounded HTTP/1 header blocks"* was published on
/// 2026-06-12 and will be true forever. Asking a server for it is non-hermetic. **Having it** is
/// not: a file that says "these are the advisories known as of 2026-10-06" is an input like any
/// other, and *this lockfile against that file* is a pure function of the two.
///
/// So the lookup is split from the check. `dependency-advisory` reads this and may fail a build;
/// `quality-gate advisories refresh` is the only thing that writes it.
///
/// ## The header
///
/// `source`, `sourceRef`, `fetched` and `contentHash` are the fields the control catalogues
/// already use, deliberately. `fetched` is the date every finding is dated with, the date an
/// acknowledgement expires against, and the date `dependency-advisory-freshness` counts from.
struct AdvisorySnapshot: Sendable, Equatable {

    /// Where the records came from — `osv`.
    let source: String
    /// The URL they were fetched from.
    let sourceRef: String
    /// The UTC date they were fetched, `YYYY-MM-DD`.
    let fetched: String
    /// `sha256:` and the hex digest of the records' canonical JSON — see ``contentHash(of:)``.
    let contentHash: String
    /// The latest `modified` among the records, as OSV wrote it.
    let newestModified: String
    /// How many records the snapshot holds.
    let recordCount: Int
    /// The OSV records, verbatim, sorted by id.
    let records: [JSONValue]

    /// The records as the matcher reads them.
    let advisories: [Advisory]

    /// The date in `fetched`. A decoded snapshot always has one.
    var fetchedDate: AdvisoryDate? { AdvisoryDate(fetched) }

    /// The default `sourceRef`: the id list the refresh reads, and the endpoint it reads each
    /// record from.
    static let osvSourceRef =
        "https://osv-vulnerabilities.storage.googleapis.com/SwiftURL/modified_id.csv + https://api.osv.dev/v1/vulns/{id}"

    /// Builds a snapshot whose header is true of `records`.
    ///
    /// Records are sorted by id so that two refreshes of the same database write the same file,
    /// and a diff between two snapshots shows advisories arriving rather than moving.
    static func make(
        records: [JSONValue], fetched: String, sourceRef: String = osvSourceRef
    ) -> AdvisorySnapshot {
        let sorted = records.sorted { ($0["id"]?.stringValue ?? "") < ($1["id"]?.stringValue ?? "") }
        return AdvisorySnapshot(
            source: "osv",
            sourceRef: sourceRef,
            fetched: fetched,
            contentHash: contentHash(of: sorted),
            newestModified: sorted.compactMap { $0["modified"]?.stringValue }.max() ?? "",
            recordCount: sorted.count,
            records: sorted,
            advisories: sorted.compactMap(Advisory.init))
    }

    /// `sha256:` and the lowercase hex SHA-256 of the records as one canonical JSON array.
    ///
    /// Taken over ``JSONValue/canonicalJSON`` rather than over the file's bytes, so the hash
    /// describes the records and survives a re-serialisation that changes nothing in them.
    static func contentHash(of records: [JSONValue]) -> String {
        let digest = SHA256.hash(data: Data(JSONValue.array(records).canonicalJSON.utf8))
        let hexDigits = Array("0123456789abcdef")
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return "sha256:" + hex
    }

    /// The snapshot as the file that is committed or bundled: pretty-printed, keys sorted, so a
    /// refresh produces a diff a person can review.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(
            source: source, sourceRef: sourceRef, fetched: fetched, contentHash: contentHash,
            newestModified: newestModified, recordCount: recordCount, records: records))
    }

    /// Reads a snapshot file, refusing one that is not what its header says it is.
    ///
    /// A snapshot is the only thing standing between a vulnerable pin and a green run, so a file
    /// that has been truncated, hand-edited or half-written must not be read as "no advisories".
    static func decode(_ data: Data) -> Result<AdvisorySnapshot, SnapshotProblem> {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            logger.warning("advisory snapshot could not be decoded: \(error.localizedDescription, privacy: .public)")
            return .failure(SnapshotProblem(reason: "it is not a snapshot file (it could not be decoded)"))
        }
        guard AdvisoryDate(file.fetched) != nil else {
            return .failure(SnapshotProblem(reason: "its `fetched` date '\(file.fetched)' is not YYYY-MM-DD"))
        }
        guard file.recordCount == file.records.count else {
            return .failure(SnapshotProblem(
                reason: "its header says \(file.recordCount) records and it holds \(file.records.count)"))
        }
        let actual = contentHash(of: file.records)
        guard actual == file.contentHash else {
            return .failure(SnapshotProblem(
                reason: "its header records contentHash \(file.contentHash) and its records hash to \(actual)"))
        }
        let advisories = file.records.compactMap(Advisory.init)
        guard advisories.count == file.records.count else {
            return .failure(SnapshotProblem(
                reason: "\(file.records.count - advisories.count) of its records have no id"))
        }
        return .success(AdvisorySnapshot(
            source: file.source, sourceRef: file.sourceRef, fetched: file.fetched,
            contentHash: file.contentHash, newestModified: file.newestModified,
            recordCount: file.recordCount, records: file.records, advisories: advisories))
    }

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DependencyAdvisory")

    /// The file's shape on disk.
    private struct File: Codable {
        let source: String
        let sourceRef: String
        let fetched: String
        let contentHash: String
        let newestModified: String
        let recordCount: Int
        let records: [JSONValue]
    }
}

/// Why a snapshot file was refused.
struct SnapshotProblem: Error, Sendable, Equatable {
    /// The reason, phrased to follow "The … advisory snapshot is not usable: ".
    let reason: String
}

/// Where a snapshot came from.
enum SnapshotOrigin: String, Sendable, Equatable {
    /// Shipped inside the gate binary. One refresh serves every repository, and the verdict is a
    /// function of the tree and the gate's version.
    case bundled
    /// Committed in the repository being checked. The verdict is a function of the tree alone.
    case committed
}

/// A snapshot file that was found, decoded or not.
struct SnapshotCandidate: Sendable {
    /// Bundled or committed.
    let origin: SnapshotOrigin
    /// Where it was read from, for a finding's `filePath`.
    let path: String
    /// The snapshot, or why the file was refused.
    let decoded: Result<AdvisorySnapshot, SnapshotProblem>

    /// Decodes `data` as the candidate from `origin`.
    init(origin: SnapshotOrigin, path: String, data: Data) {
        self.init(origin: origin, path: path, decoded: AdvisorySnapshot.decode(data))
    }

    /// A candidate whose outcome is already known — a file that exists and could not be read.
    init(origin: SnapshotOrigin, path: String, decoded: Result<AdvisorySnapshot, SnapshotProblem>) {
        self.origin = origin
        self.path = path
        self.decoded = decoded
    }
}

/// Finds the snapshots a run may use.
enum AdvisorySnapshotStore {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DependencyAdvisory")

    /// The largest snapshot file that will be read. The whole ecosystem is under 1 MB today; a
    /// file thirty times that is not a snapshot.
    static let maximumBytes = 32 * 1024 * 1024

    /// The snapshot shipped with this gate, or `nil` when the resource is missing.
    static func bundled() -> SnapshotCandidate? {
        guard let url = Bundle.module.url(forResource: "swifturl.advisories", withExtension: "json") else {
            return nil
        }
        return SnapshotCandidate(origin: .bundled, path: "(bundled with quality-gate)", decoded: read(url))
    }

    /// The snapshot committed at `relativePath` under `projectRoot`, or `nil` when there is none.
    ///
    /// A file that is there and cannot be read is a candidate that failed, not an absence: the
    /// repository meant to supply a snapshot, and the run has to say it could not use it.
    static func committed(projectRoot: URL, relativePath: String) -> SnapshotCandidate? {
        let url = projectRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil } // SAFETY: read-only probe for an optional file under the project root
        return SnapshotCandidate(origin: .committed, path: relativePath, decoded: read(url))
    }

    /// Reads and decodes a snapshot file, refusing one too large to be one.
    private static func read(_ url: URL) -> Result<AdvisorySnapshot, SnapshotProblem> {
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else {
                return .failure(SnapshotProblem(
                    reason: "it is \(size) bytes, over the \(maximumBytes) byte limit for a snapshot"))
            }
            return AdvisorySnapshot.decode(try Data(contentsOf: url))
        } catch {
            logger.warning("advisory snapshot at \(url.path, privacy: .public) could not be read: \(error.localizedDescription, privacy: .public)")
            return .failure(SnapshotProblem(reason: "it could not be read"))
        }
    }
}
