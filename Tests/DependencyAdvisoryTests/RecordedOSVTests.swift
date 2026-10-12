import Foundation
import Testing
import QualityGateCore
@testable import DependencyAdvisory

/// Real OSV data, recorded once on 2026-10-06 (see `Fixtures/osv/README.md`).
enum RecordedOSV {

    /// The directory the recordings live in. Read by path: the test target excludes `Fixtures`,
    /// so nothing here is a bundle resource.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/osv")

    static let retrieved = "2026-10-06"

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The twenty recorded records, verbatim.
    static func records() throws -> [JSONValue] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("records").path)
        return try names.filter { $0.hasSuffix(".json") }.sorted().map { name in
            try JSONDecoder().decode(JSONValue.self, from: data("records/\(name)"))
        }
    }

    /// A snapshot holding exactly the recorded records, dated the day they were retrieved.
    static func snapshot() throws -> AdvisorySnapshot {
        AdvisorySnapshot.make(records: try records(), fetched: retrieved)
    }

    static func candidate(_ origin: SnapshotOrigin = .bundled) throws -> SnapshotCandidate {
        SnapshotCandidate(origin: origin, path: "(recorded)", data: try snapshot().encoded())
    }

    /// The recorded request and response, paired by position.
    static func exchanges() throws -> [(name: String, version: String, ids: [String])] {
        struct Request: Decodable {
            struct Query: Decodable {
                struct Package: Decodable { let name: String }
                let package: Package
                let version: String
            }
            let queries: [Query]
        }
        let request = try JSONDecoder().decode(Request.self, from: data("querybatch-request.json"))
        let results = try OSVQueryBatch.parse(data("querybatch-response.json"), expecting: request.queries.count)
        return zip(request.queries, results).map { ($0.package.name, $0.version, $1.ids) }
    }
}

/// The local matcher against the live API's own answers.
///
/// Neither is reference truth alone. The proposal's measurement found the two disagreeing
/// twice, each right once; this pins both — agreement wherever the API can answer, and the
/// recorded queries where the local matcher is right and the API is silent.
@Suite("dependency-advisory: recorded OSV responses (2026-10-06)")
struct RecordedOSVTests {

    private func localIDs(name: String, version: String) throws -> [String] {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("pkg", "https://\(name).git", version)])],
            bundled: try RecordedOSV.candidate())
        #expect(outcome.findings.allSatisfy {
            $0.ruleId == "dep-advisory.vulnerable-pin" || $0.ruleId == "dep-advisory.vulnerable-pin-by-name"
        })
        return outcome.findings.compactMap { finding in
            finding.message.split(separator: " ").first { $0.hasPrefix("GHSA-") }.map(String.init)
        }.sorted()
    }

    @Test("the recording holds what its README says it holds")
    func recordingIsIntact() throws {
        #expect(try RecordedOSV.records().count == 20)
        #expect(try RecordedOSV.snapshot().advisories.filter { $0.withdrawn != nil }.count == 3)
        #expect(try RecordedOSV.exchanges().count == 11)
    }

    /// swift-nio at 2.86.0 — the case the brief names. Three advisories, all fixed in 2.100.0.
    @Test("swift-nio 2.86.0 is reached by exactly the three advisories the live API returned")
    func swiftNIOBeforeTheFix() throws {
        let recorded = try #require(try RecordedOSV.exchanges().first {
            $0.name == "github.com/apple/swift-nio" && $0.version == "2.86.0"
        })
        #expect(recorded.ids == ["GHSA-cq87-8r7h-962v", "GHSA-r3rc-9hpw-54v9", "GHSA-rj37-6j9x-74q6"])
        #expect(try localIDs(name: "github.com/apple/swift-nio", version: "2.86.0") == recorded.ids)
    }

    @Test("marmelroy/Zip 2.1.2 is reached by GHSA-g454-wj9r-jpg4, as the live API returned")
    func zip() throws {
        #expect(try localIDs(name: "github.com/marmelroy/Zip", version: "2.1.2") == ["GHSA-g454-wj9r-jpg4"])
    }

    /// Every recorded query that names a package by URL, in the case OSV files it under, and for
    /// a package with no by-name record: the local matcher must return what the API returned.
    @Test("wherever the API can answer, the local matcher gives the same ids", arguments: [
        ("github.com/apple/swift-nio", "2.86.0"),
        ("github.com/apple/swift-nio", "2.103.0"),
        ("github.com/apple/swift-nio", "2.12.0"),
        ("github.com/marmelroy/Zip", "2.1.2"),
        ("github.com/apple/swift-nio-http2", "1.46.0"),
        ("github.com/apple/swift-nio-extras", "1.33.0"),
    ])
    func agreesWithTheAPI(name: String, version: String) throws {
        let recorded = try #require(try RecordedOSV.exchanges().first { $0.name == name && $0.version == version })
        #expect(try localIDs(name: name, version: version) == recorded.ids.sorted())
    }

    /// The places the documented query is blind, each recorded.
    @Test("where the API is silent and the advisory exists, the local matcher still finds it", arguments: [
        // Lower-cased URL: the API matches names case-sensitively.
        ("github.com/marmelroy/zip", "2.1.2", [String](), ["GHSA-g454-wj9r-jpg4"]),
        // Filed under a bare name: the query by URL returns only the record filed by URL.
        ("github.com/apple/swift-nio-http2", "1.43.0", ["GHSA-4px2-pw77-vc85"], ["GHSA-4px2-pw77-vc85", "GHSA-q3g2-m552-3r9c"]),
        // The same record again, at a version seven URL-filed advisories also reach: the API
        // returns those seven and still not the eighth.
        ("github.com/apple/swift-nio-http2", "1.19.1",
         ["GHSA-4px2-pw77-vc85", "GHSA-ccw9-q5h2-8c2w", "GHSA-pgfx-g6rc-8cjv", "GHSA-q36x-r5x4-h4q6",
          "GHSA-qppj-fm5r-hxr3", "GHSA-w3f6-pc54-gfw7", "GHSA-xvr7-p2c6-j83w"],
         ["GHSA-4px2-pw77-vc85", "GHSA-ccw9-q5h2-8c2w", "GHSA-pgfx-g6rc-8cjv", "GHSA-q36x-r5x4-h4q6",
          "GHSA-q3g2-m552-3r9c", "GHSA-qppj-fm5r-hxr3", "GHSA-w3f6-pc54-gfw7", "GHSA-xvr7-p2c6-j83w"]),
        // Filed under a bare name, and nothing else filed by URL.
        ("github.com/apple/swift-crypto", "4.2.0", [String](), ["GHSA-9m44-rr2w-ppp7"]),
    ])
    func findsWhatTheAPICannot(name: String, version: String, api: [String], local: [String]) throws {
        let recorded = try #require(try RecordedOSV.exchanges().first { $0.name == name && $0.version == version })
        #expect(recorded.ids.sorted() == api)
        #expect(try localIDs(name: name, version: version) == local)
    }

    @Test("the by-name records are reported under the by-name rule, and the rest are not")
    func byNameRuleOnRealData() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([
                .version("swift-nio-http2", "https://github.com/apple/swift-nio-http2.git", "1.43.0"),
            ])],
            bundled: try RecordedOSV.candidate())
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin", "dep-advisory.vulnerable-pin-by-name"])
        #expect(outcome.findings.map(\.severity) == [.warning, .warning])
        #expect(outcome.findings.first?.message == "swift-nio-http2 1.43.0 is affected by GHSA-4px2-pw77-vc85 "
            + "(CVE-2026-28898, MODERATE): SwiftNIO HTTP/2: HTTP/2-to-HTTP/1 Request Smuggling via unvalidated "
            + ":path pseudo-header in HTTP2ToHTTP1Codec. "
            + "Affected: < 1.44.0; fixed in 1.44.0. Pin: github.com/apple/swift-nio-http2. "
            + "Advisory data as of 2026-10-06. [CWE-1395]")
    }

    @Test("the coverage note counts the real records, their withdrawals and their packages")
    func coverageOnRealData() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([
                .version("swift-nio", "https://github.com/apple/swift-nio.git", "2.86.0"),
                .version("swift-nio-http2", "https://github.com/apple/swift-nio-http2.git", "1.46.0"),
                .branch("indexstore-db", "https://github.com/apple/indexstore-db.git", "main"),
            ])],
            bundled: try RecordedOSV.candidate())
        #expect(outcome.diagnostics.last?.message == "dependency-advisory examined 1 lockfile · 3 pins · "
            + "3 third-party · 2 evaluable by version · 1 unevaluable · 1 affected by 3 advisories · 0 acknowledged · "
            + "snapshot osv/SwiftURL fetched 2026-10-06 (20 records, 3 withdrawn, 5 packages; bundled)")
    }
}
