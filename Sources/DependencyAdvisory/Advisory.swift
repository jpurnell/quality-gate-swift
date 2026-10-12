import Foundation
import QualityGateCore

/// One OSV record, reduced to what matching and reporting read.
///
/// Built from the verbatim ``JSONValue`` a snapshot holds. Nothing here is recomputed: the
/// severity is GitHub's label, the CVSS vector is carried as text, and a range is the list of
/// events OSV published in the order it published them.
struct Advisory: Sendable, Equatable {

    /// One `introduced` / `fixed` / `last_affected` / `limit` event.
    struct Event: Sendable, Equatable {
        /// The event's kind, as OSV names it.
        let kind: String
        /// The version, or commit, the event names.
        let value: String
    }

    /// One range of affected versions.
    struct Range: Sendable, Equatable {
        /// `SEMVER`, `ECOSYSTEM` or `GIT`.
        let type: String
        /// The events, in published order.
        let events: [Event]
    }

    /// One package the record affects.
    struct Affected: Sendable, Equatable {
        /// The ecosystem — `SwiftURL` for the entries this checker reads.
        let ecosystem: String
        /// The package name: a repository URL without scheme or `.git`, or, in three records of
        /// the export, a bare name.
        let name: String
        /// The affected ranges.
        let ranges: [Range]
        /// Versions listed explicitly.
        let versions: [String]
    }

    /// The record's id — `GHSA-…` for everything in the Swift export.
    let id: String
    /// Other names for the same advisory, typically one `CVE-…`.
    let aliases: [String]
    /// The one-line summary.
    let summary: String
    /// When the record was last modified, as OSV wrote it.
    let modified: String
    /// When the record was withdrawn, if it was.
    let withdrawn: String?
    /// GitHub's severity label, upper-cased: `CRITICAL`, `HIGH`, `MODERATE`, `LOW`.
    let severityLabel: String?
    /// The first CVSS vector the record carries, quoted and never scored.
    let cvssVector: String?
    /// The packages the record affects, in every ecosystem it names.
    let affected: [Affected]

    /// The ecosystem OSV files Swift packages under.
    static let swiftEcosystem = "SwiftURL"

    /// The entries that name a Swift package.
    ///
    /// The export is not Swift-only inside a record: one advisory lists `pubnub` on npm, Maven,
    /// Go, NuGet, RubyGems, crates.io, Packagist, Pub and PyPI beside its Swift entry. Matching
    /// any of those by name against a lockfile would be matching a different package.
    var swiftAffected: [Affected] { affected.filter { $0.ecosystem == Self.swiftEcosystem } }

    /// Reads a record, or fails when it has no id.
    init?(_ record: JSONValue) {
        guard let id = record["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        self.aliases = (record["aliases"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.summary = record["summary"]?.stringValue ?? ""
        self.modified = record["modified"]?.stringValue ?? ""
        self.withdrawn = record["withdrawn"]?.stringValue
        self.severityLabel = record["database_specific"]?["severity"]?.stringValue?.uppercased()
        self.cvssVector = (record["severity"]?.arrayValue ?? []).compactMap { $0["score"]?.stringValue }.first
        self.affected = (record["affected"]?.arrayValue ?? []).compactMap(Self.affected)
    }

    private static func affected(_ entry: JSONValue) -> Affected? {
        guard let name = entry["package"]?["name"]?.stringValue, !name.isEmpty else { return nil }
        return Affected(
            ecosystem: entry["package"]?["ecosystem"]?.stringValue ?? "",
            name: name,
            ranges: (entry["ranges"]?.arrayValue ?? []).map(range),
            versions: (entry["versions"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    private static func range(_ range: JSONValue) -> Range {
        var events: [Event] = []
        for event in range["events"]?.arrayValue ?? [] {
            guard case .object(let members) = event else { continue }
            // One key per event in OSV; sorted so that an object with two is read the same way twice.
            for key in members.keys.sorted() {
                if let value = members[key]?.stringValue { events.append(Event(kind: key, value: value)) }
            }
        }
        return Range(type: range["type"]?.stringValue ?? "", events: events)
    }
}
