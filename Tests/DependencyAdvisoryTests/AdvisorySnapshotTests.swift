import Foundation
import Testing
import QualityGateCore
@testable import DependencyAdvisory

/// The snapshot: which one is used, what it says about itself, and what happens when it lies.
@Suite("dependency-advisory: snapshot")
struct AdvisorySnapshotTests {

    private typealias Pin = AdvisoryFixture.Pin

    private let nio = AdvisoryFixture.lockfile([
        .version("swift-nio", "https://github.com/apple/swift-nio.git", "2.99.0"),
    ])

    // MARK: - Absence

    @Test("19. third-party pins and no snapshot anywhere is reported — never a silent pass")
    func noSnapshot() {
        let outcome = audit([nio])
        #expect(outcome.diagnostics == [
            Diagnostic(
                severity: .warning,
                message: "1 third-party pin in 1 lockfile was not checked against any advisory: no advisory "
                    + "snapshot is available — none is bundled with this gate and none is committed at "
                    + "`.quality-gate/advisories/swifturl.json`. Run `quality-gate advisories refresh`.",
                ruleId: "dep-advisory.no-snapshot"),
            Diagnostic(
                severity: .note,
                message: "dependency-advisory examined 1 lockfile · 1 pin · 1 third-party · 1 evaluable by version · "
                    + "0 unevaluable · 0 affected by 0 advisories · 0 acknowledged · 1 not checked · snapshot none",
                ruleId: "dep-advisory.coverage"),
        ])
        #expect(outcome.status == .warning)
    }

    @Test("20. only the author's own packages pinned and no snapshot is clean — there is nothing to look up")
    func ownPackagesNeedNoSnapshot() {
        let own = AdvisoryFixture.lockfile([
            .version("quality-gate-types", "https://github.com/jpurnell/quality-gate-types.git", "1.7.0"),
        ])
        let outcome = audit([own], configuration: DependencyAuditorConfig(ownPackages: ["github.com/JPurnell/"]))
        #expect(outcome.findings.isEmpty)
        #expect(outcome.status == .passed)
        #expect(outcome.tally.thirdPartyPins == 0)
    }

    @Test("an own package is still matched when a snapshot names it")
    func ownPackagesAreStillChecked() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0020", package: "github.com/jpurnell/quality-gate-types",
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "2.0.0")])])
        let own = AdvisoryFixture.lockfile([
            .version("quality-gate-types", "https://github.com/jpurnell/quality-gate-types.git", "1.7.0"),
        ])
        let outcome = audit(
            [own], bundled: try AdvisoryFixture.candidate(records: [record]),
            configuration: DependencyAuditorConfig(ownPackages: ["github.com/jpurnell/"]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
    }

    // MARK: - Selection

    /// The same lockfile, clean under the older snapshot and affected under the newer one: the
    /// verdict shows which was read, and the coverage note says so in words.
    @Test("21. of a bundled and a committed snapshot, the later `fetched` is used and named", arguments: [
        ("2026-09-01", "2026-10-01", "committed"),
        ("2026-10-01", "2026-09-01", "bundled"),
        ("2026-10-01", "2026-10-01", "committed"),
    ])
    func newestSnapshotWins(bundledDate: String, committedDate: String, expected: String) throws {
        let withFinding = [AdvisoryFixture.nioHeaderBlocks]
        let bundled = try AdvisoryFixture.candidate(
            .bundled, fetched: bundledDate, records: expected == "bundled" ? withFinding : [])
        let committed = try AdvisoryFixture.candidate(
            .committed, fetched: committedDate, records: expected == "committed" ? withFinding : [])

        let outcome = audit([nio], bundled: bundled, committed: committed)

        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
        let fetched = expected == "bundled" ? bundledDate : committedDate
        #expect(outcome.diagnostics.last == Diagnostic(
            severity: .note,
            message: "dependency-advisory examined 1 lockfile · 1 pin · 1 third-party · 1 evaluable by version · "
                + "0 unevaluable · 1 affected by 1 advisory · 0 acknowledged · snapshot osv/SwiftURL fetched "
                + "\(fetched) (1 record, 0 withdrawn, 1 package; \(expected))",
            ruleId: "dep-advisory.coverage"))
    }

    // MARK: - Integrity

    @Test("a snapshot round-trips: what `make` writes, `decode` accepts")
    func roundTrip() throws {
        let data = try AdvisoryFixture.snapshotData(
            fetched: "2026-10-06", records: [AdvisoryFixture.zipTraversal, AdvisoryFixture.nioHeaderBlocks])
        let snapshot = try AdvisorySnapshot.decode(data).get()

        #expect(snapshot.source == "osv")
        #expect(snapshot.fetched == "2026-10-06")
        #expect(snapshot.recordCount == 2)
        // Sorted by id, whatever order they arrived in.
        #expect(snapshot.advisories.map(\.id) == ["GHSA-g454-wj9r-jpg4", "GHSA-rj37-6j9x-74q6"])
        #expect(snapshot.newestModified == "2026-09-10T03:50:50Z")
        #expect(snapshot.contentHash.hasPrefix("sha256:"))
        #expect(snapshot.contentHash.count == 7 + 64)
    }

    /// The hash is over the records' content, so it cannot depend on how a serialiser happened to
    /// order an object's keys or escape a slash.
    @Test("the content hash ignores key order and whitespace, and nothing else")
    func hashIsCanonical() throws {
        let one = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"id": "GHSA-a", "modified": "2026-01-01T00:00:00Z", "n": [1, 2.5, true, null]}"#.utf8))
        let reordered = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{ "n":[1,2.5,true,null], "modified":"2026-01-01T00:00:00Z", "id":"GHSA-a" }"#.utf8))
        let changed = try JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"id": "GHSA-a", "modified": "2026-01-01T00:00:00Z", "n": [1, 2.5, false, null]}"#.utf8))

        #expect(AdvisorySnapshot.contentHash(of: [one]) == AdvisorySnapshot.contentHash(of: [reordered]))
        #expect(AdvisorySnapshot.contentHash(of: [one]) != AdvisorySnapshot.contentHash(of: [changed]))
        #expect(AdvisorySnapshot.contentHash(of: [one]) != AdvisorySnapshot.contentHash(of: [one, one]))
        #expect(AdvisorySnapshot.contentHash(of: []) == "sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945")
    }

    @Test("22. a snapshot whose hash does not match its records is an error, and nothing is reported from it")
    func corruptSnapshot() throws {
        // A record edited after the header was written: the range now ends before the pin.
        let honest = try AdvisoryFixture.snapshotData(records: [AdvisoryFixture.nioHeaderBlocks])
        let text = try #require(String(data: honest, encoding: .utf8))
        let tampered = Data(text.replacingOccurrences(of: "2.100.0", with: "2.99.1").utf8)
        #expect(tampered != honest)

        let outcome = audit(
            [nio], committed: SnapshotCandidate(
                origin: .committed, path: ".quality-gate/advisories/swifturl.json", data: tampered))

        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.snapshot-corrupt", "dep-advisory.no-snapshot"])
        let corrupt = try #require(outcome.findings.first)
        #expect(corrupt.severity == .error)
        #expect(corrupt.filePath == ".quality-gate/advisories/swifturl.json")
        #expect(corrupt.message.hasPrefix(
            "The committed advisory snapshot is not usable: its header records contentHash sha256:"))
        #expect(corrupt.message.hasSuffix("No advisory finding is reported from it."))
        #expect(outcome.status == .failed)
    }

    @Test("a corrupt committed snapshot does not disarm a sound bundled one")
    func corruptCommittedFallsBackToBundled() throws {
        let outcome = audit(
            [nio],
            bundled: try AdvisoryFixture.candidate(.bundled, records: [AdvisoryFixture.nioHeaderBlocks]),
            committed: SnapshotCandidate(
                origin: .committed, path: ".quality-gate/advisories/swifturl.json", data: Data("{".utf8)))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.snapshot-corrupt", "dep-advisory.vulnerable-pin"])
        #expect(outcome.findings.first?.message == "The committed advisory snapshot is not usable: it is not a "
            + "snapshot file (it could not be decoded). No advisory finding is reported from it.")
    }

    @Test("a header that miscounts its records, or misdates itself, is corrupt", arguments: [
        (#""recordCount" : 1"#, #""recordCount" : 7"#, "its header says 7 records and it holds 1"),
        (#""fetched" : "2026-10-01""#, #""fetched" : "last Tuesday""#, "its `fetched` date 'last Tuesday' is not YYYY-MM-DD"),
    ])
    func dishonestHeader(original: String, replacement: String, reason: String) throws {
        let honest = try AdvisoryFixture.snapshotData(records: [AdvisoryFixture.nioHeaderBlocks])
        let text = try #require(String(data: honest, encoding: .utf8))
        #expect(text.contains(original))
        let edited = Data(text.replacingOccurrences(of: original, with: replacement).utf8)
        guard case .failure(let problem) = AdvisorySnapshot.decode(edited) else {
            Issue.record("the edited snapshot was accepted")
            return
        }
        #expect(problem.reason == reason)
    }

    // MARK: - The snapshot this gate ships

    /// Invariants only. The bundled file is refreshed with each release, so a test that pinned its
    /// contents would be a test of the calendar.
    @Test("the bundled snapshot loads, verifies, and holds the advisories the proposal measured")
    func bundledSnapshotIsSound() throws {
        let candidate = try #require(AdvisorySnapshotStore.bundled())
        let snapshot = try candidate.decoded.get()

        #expect(snapshot.source == "osv")
        #expect(snapshot.fetched >= "2026-10-06")
        #expect(snapshot.recordCount >= 64)
        #expect(snapshot.recordCount == snapshot.advisories.count)
        let ids = Set(snapshot.advisories.map(\.id))
        for id in ["GHSA-rj37-6j9x-74q6", "GHSA-r3rc-9hpw-54v9", "GHSA-cq87-8r7h-962v",
                   "GHSA-4px2-pw77-vc85", "GHSA-q3g2-m552-3r9c", "GHSA-6ph5-fww6-vfwv", "GHSA-g454-wj9r-jpg4"] {
            #expect(ids.contains(id), "\(id) is missing from the bundled snapshot")
        }
    }

    // MARK: - Lockfiles

    @Test("a version-1 lockfile is read too")
    func versionOneLockfile() throws {
        let text = """
        {
          "object": {
            "pins": [
              {
                "package": "swift-nio",
                "repositoryURL": "https://github.com/apple/swift-nio.git",
                "state": { "branch": null, "revision": "abc", "version": "2.99.0" }
              }
            ]
          },
          "version": 1
        }
        """
        let lockfile = try #require(Lockfile.parse(path: "Package.resolved", contents: text))
        #expect(lockfile.pins == [
            LockfilePin(
                identity: "swift-nio", location: "https://github.com/apple/swift-nio.git",
                version: "2.99.0", branch: nil, revision: "abc", line: 6),
        ])
    }

    @Test("a file that is not a lockfile is not parsed as an empty one")
    func notALockfile() {
        #expect(Lockfile.parse(path: "Package.resolved", contents: "not json") == nil)
        #expect(Lockfile.parse(path: "Package.resolved", contents: #"{"version": 3}"#) == nil)
    }

    @Test("an unreadable lockfile is reported, and the run does not pass on the others")
    func unreadableLockfile() throws {
        let outcome = AdvisoryAudit.run(
            lockfiles: [nio], unreadable: ["Broken/Package.resolved"],
            bundled: try AdvisoryFixture.candidate(records: []), committed: nil, configuration: .default)
        #expect(outcome.findings == [
            Diagnostic(
                severity: .warning,
                message: "`Broken/Package.resolved` could not be read as a lockfile, so its pins were not "
                    + "checked against any advisory.",
                filePath: "Broken/Package.resolved",
                ruleId: "dep-advisory.unevaluable"),
        ])
    }
}
