import Foundation
import QualityGateCore
@testable import DependencyAdvisory

/// Hand-written lockfiles and advisory records, small enough to read in the test that uses them.
///
/// The proposal asks for fixtures of this kind for the matcher (`AnAdvisoryIsADatedFact.md` §6),
/// and names the live API as reference truth for the pairs it can answer. The recorded responses
/// that hold the matcher to that truth are in `Fixtures/osv/`; these builders are for everything
/// the API cannot be asked — a withdrawn record, an unparseable bound, a snapshot that lies about
/// its own hash.
enum AdvisoryFixture {

    /// One pin, as `Package.resolved` writes it.
    struct Pin {
        let identity: String
        let location: String
        let state: String

        static func version(_ identity: String, _ location: String, _ version: String) -> Pin {
            Pin(identity: identity, location: location,
                state: #""revision" : "0000000000000000000000000000000000000001", "version" : "\#(version)""#)
        }

        static func branch(_ identity: String, _ location: String, _ branch: String) -> Pin {
            Pin(identity: identity, location: location,
                state: #""branch" : "\#(branch)", "revision" : "0000000000000000000000000000000000000002""#)
        }

        static func revision(_ identity: String, _ location: String) -> Pin {
            Pin(identity: identity, location: location,
                state: #""revision" : "0000000000000000000000000000000000000003""#)
        }
    }

    /// A version-3 `Package.resolved` holding `pins`, laid out the way SwiftPM writes one.
    ///
    /// The layout matters: a finding is reported at the line of the pin's `location`, so the
    /// first pin's location is always line 7 and each further pin adds eight lines.
    static func lockfileText(_ pins: [Pin]) -> String {
        let body = pins.map { pin in
            """
                {
                  "identity" : "\(pin.identity)",
                  "kind" : "remoteSourceControl",
                  "location" : "\(pin.location)",
                  "state" : {
                    \(pin.state)
                  }
                }
            """
        }.joined(separator: ",\n")
        return "{\n  \"originHash\" : \"abc\",\n  \"pins\" : [\n\(body)\n  ],\n  \"version\" : 3\n}\n"
    }

    /// A parsed lockfile at `path`.
    static func lockfile(_ pins: [Pin], path: String = "Package.resolved") -> Lockfile {
        Lockfile.parse(path: path, contents: lockfileText(pins)) ?? Lockfile(path: path, pins: [])
    }

    /// One `SEMVER` or `ECOSYSTEM` range, as a JSON object.
    static func range(_ events: [(String, String)], type: String = "SEMVER") -> String {
        let rendered = events.map { #"{"\#($0.0)": "\#($0.1)"}"# }.joined(separator: ", ")
        return #"{"type": "\#(type)", "events": [\#(rendered)]}"#
    }

    /// One OSV record, as JSON text.
    static func record(
        id: String,
        aliases: [String] = [],
        summary: String = "A test advisory",
        severity: String? = "HIGH",
        cvss: (type: String, score: String)? = nil,
        package: String,
        ecosystem: String = "SwiftURL",
        ranges: [String],
        versions: [String] = [],
        withdrawn: String? = nil,
        modified: String = "2026-09-10T03:50:50Z"
    ) -> String {
        var fields: [String] = [
            #""id": "\#(id)""#,
            #""modified": "\#(modified)""#,
            #""summary": "\#(summary)""#,
            #""aliases": [\#(aliases.map { "\"\($0)\"" }.joined(separator: ", "))]"#,
        ]
        if let withdrawn { fields.append(#""withdrawn": "\#(withdrawn)""#) }
        if let severity { fields.append(#""database_specific": {"severity": "\#(severity)"}"#) }
        if let cvss { fields.append(#""severity": [{"type": "\#(cvss.type)", "score": "\#(cvss.score)"}]"#) }
        let listed = versions.isEmpty
            ? ""
            : #", "versions": [\#(versions.map { "\"\($0)\"" }.joined(separator: ", "))]"#
        fields.append(
            #""affected": [{"package": {"ecosystem": "\#(ecosystem)", "name": "\#(package)"}, "#
                + #""ranges": [\#(ranges.joined(separator: ", "))]\#(listed)}]"#)
        return "{" + fields.joined(separator: ", ") + "}"
    }

    /// The snapshot file holding `records`, with a header that is true of them.
    static func snapshotData(fetched: String = "2026-10-01", records: [String]) throws -> Data {
        let values = try records.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        return try AdvisorySnapshot.make(records: values, fetched: fetched).encoded()
    }

    /// A snapshot candidate as the checker would load it.
    static func candidate(
        _ origin: SnapshotOrigin = .bundled, fetched: String = "2026-10-01", records: [String]
    ) throws -> SnapshotCandidate {
        SnapshotCandidate(
            origin: origin,
            path: origin == .bundled ? "(bundled)" : ".quality-gate/advisories/swifturl.json",
            data: try snapshotData(fetched: fetched, records: records))
    }

    // MARK: - The records the proposal's tests name

    /// GHSA-rj37-6j9x-74q6 as OSV publishes it: `introduced 0`, `fixed 2.100.0`, HIGH.
    static let nioHeaderBlocks = record(
        id: "GHSA-rj37-6j9x-74q6", aliases: ["CVE-2026-28980"],
        summary: "SwiftNIO NIOHTTP1: HTTPDecoder accepts unbounded HTTP/1 header blocks, enabling remote DoS",
        severity: "HIGH", package: "github.com/apple/swift-nio",
        ranges: [range([("introduced", "0"), ("fixed", "2.100.0")])])

    /// GHSA-g454-wj9r-jpg4: no fixed version, `last_affected 2.1.2`, and a capital in the name.
    static let zipTraversal = record(
        id: "GHSA-g454-wj9r-jpg4", aliases: ["CVE-2023-39135"],
        summary: "Zip Path Traversal vulnerability",
        severity: "HIGH", package: "github.com/marmelroy/Zip",
        ranges: [range([("introduced", "0"), ("last_affected", "2.1.2")])])

    /// GHSA-q3g2-m552-3r9c: the record that names its package without a URL.
    static let http2ByName = record(
        id: "GHSA-q3g2-m552-3r9c", aliases: ["CVE-2026-64785"],
        summary: "swift-nio-http2 is missing CR/LF/NUL validation in header values",
        severity: "MODERATE", package: "swift-nio-http2",
        ranges: [range([("introduced", "0"), ("fixed", "1.45.0")])])
}

/// Runs the hermetic audit over fixtures, with the configuration defaulted.
func audit(
    _ lockfiles: [Lockfile],
    bundled: SnapshotCandidate? = nil,
    committed: SnapshotCandidate? = nil,
    configuration: DependencyAuditorConfig = .default
) -> AdvisoryAuditOutcome {
    AdvisoryAudit.run(
        lockfiles: lockfiles, bundled: bundled, committed: committed, configuration: configuration)
}

extension AdvisoryAuditOutcome {
    /// The findings, without the coverage note every run ends with.
    var findings: [Diagnostic] { diagnostics.filter { $0.ruleId != AdvisoryRule.coverage } }
}
