import Foundation
import Testing
import QualityGateCore
@testable import DependencyAdvisory

/// Which pins an advisory reaches.
///
/// Tests 1–4 and 9 of `AnAdvisoryIsADatedFact.md` §6 were confirmed against `api.osv.dev` when the
/// proposal was written (2026-10-01), and the pairs the API can answer were recorded again on
/// 2026-10-06 into `Fixtures/osv/` — `RecordedOSVTests` holds this matcher to those responses.
/// The cases here are the ones worth reading: each is a way the measurement script that preceded
/// this checker was wrong.
@Suite("dependency-advisory: matching")
struct AdvisoryMatchingTests {

    private typealias Pin = AdvisoryFixture.Pin

    // MARK: - Identity

    @Test("1. a pin inside the affected range is reported, naming the advisory, its alias, its severity and the fix")
    func pinInsideRangeIsReported() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("swift-nio", "https://github.com/apple/swift-nio.git", "2.99.0")])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks]))

        #expect(outcome.findings == [
            Diagnostic(
                severity: .error,
                message: "swift-nio 2.99.0 is affected by GHSA-rj37-6j9x-74q6 (CVE-2026-28980, HIGH): "
                    + "SwiftNIO NIOHTTP1: HTTPDecoder accepts unbounded HTTP/1 header blocks, enabling remote DoS. "
                    + "Affected: < 2.100.0; fixed in 2.100.0. Pin: github.com/apple/swift-nio. "
                    + "Advisory data as of 2026-10-01. [CWE-1395]",
                filePath: "Package.resolved",
                lineNumber: 7,
                ruleId: "dep-advisory.vulnerable-pin",
                suggestedFix: "Update swift-nio to 2.100.0 or later: `swift package update swift-nio`"),
        ])
        #expect(outcome.status == .failed)
    }

    @Test("2. the fixed version itself is clean — the upper bound is exclusive")
    func fixedVersionIsClean() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("swift-nio", "https://github.com/apple/swift-nio.git", "2.100.0")])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks]))
        #expect(outcome.findings.isEmpty)
        #expect(outcome.status == .passed)
    }

    @Test("3. a package name with a capital in it matches the pin that spells it the same way")
    func capitalisedNameMatches() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("zip", "https://github.com/marmelroy/Zip.git", "2.1.2")])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.zipTraversal]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
    }

    /// The live API returns nothing for `github.com/marmelroy/zip`; a lockfile records whatever
    /// case the manifest that introduced the dependency typed.
    @Test("4. the same pin lower-cased still matches — the test the live API fails")
    func lowerCasedLocationStillMatches() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("zip", "https://github.com/marmelroy/zip.git", "2.1.2")])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.zipTraversal]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
        #expect(outcome.findings.first?.message.contains("Pin: github.com/marmelroy/zip.") == true)
    }

    @Test("5. an SSH location normalises to the same identity")
    func sshLocationNormalises() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("swift-nio", "git@github.com:apple/swift-nio.git", "2.99.0")])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
    }

    @Test("location spellings all reduce to host/path", arguments: [
        ("https://github.com/apple/swift-nio.git", "github.com/apple/swift-nio"),
        ("https://github.com/apple/swift-nio", "github.com/apple/swift-nio"),
        ("https://github.com/apple/swift-nio/", "github.com/apple/swift-nio"),
        ("http://github.com/apple/swift-nio.git/", "github.com/apple/swift-nio"),
        ("git@github.com:apple/swift-nio.git", "github.com/apple/swift-nio"),
        ("ssh://git@github.com/apple/swift-nio.git", "github.com/apple/swift-nio"),
        ("git://github.com/marmelroy/Zip", "github.com/marmelroy/Zip"),
        ("https://user:token@example.com/team/Pkg.git", "example.com/team/Pkg"),
        ("github.com/vapor/vapor", "github.com/vapor/vapor"),
    ])
    func identityNormalisation(location: String, expected: String) {
        #expect(AdvisoryMatcher.identity(ofLocation: location) == expected)
    }

    @Test("6. a record that names no URL is matched by last path component, under its own rule id, showing both spellings")
    func byNameMatch() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([
                .version("swift-nio-http2", "https://github.com/apple/swift-nio-http2.git", "1.43.0"),
            ])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.http2ByName]))

        #expect(outcome.findings == [
            Diagnostic(
                severity: .warning,
                message: "swift-nio-http2 1.43.0 is affected by GHSA-q3g2-m552-3r9c (CVE-2026-64785, MODERATE): "
                    + "swift-nio-http2 is missing CR/LF/NUL validation in header values. "
                    + "Affected: < 1.45.0; fixed in 1.45.0. Pin: github.com/apple/swift-nio-http2, matched by name — "
                    + "the advisory names the package `swift-nio-http2`, not a URL. "
                    + "Advisory data as of 2026-10-01. [CWE-1395]",
                filePath: "Package.resolved",
                lineNumber: 7,
                ruleId: "dep-advisory.vulnerable-pin-by-name",
                suggestedFix: "Update swift-nio-http2 to 1.45.0 or later: `swift package update swift-nio-http2`"),
        ])
    }

    @Test("7. the by-name record's fixed version is clean")
    func byNameFixedVersionIsClean() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([
                .version("swift-nio-http2", "https://github.com/apple/swift-nio-http2.git", "1.45.0"),
            ])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.http2ByName]))
        #expect(outcome.findings.isEmpty)
    }

    /// An advisory filed under one organisation does not name a pin under the other, and 79
    /// repositories in the portfolio pin a package that moved.
    @Test("a package that moved from apple/ to swiftlang/ matches under either organisation", arguments: [
        ("https://github.com/apple/swift-syntax.git", "github.com/swiftlang/swift-syntax"),
        ("https://github.com/swiftlang/swift-syntax.git", "github.com/apple/swift-syntax"),
    ])
    func renamedOrganisation(location: String, advisoryPackage: String) throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0001", package: advisoryPackage,
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "601.0.0")])])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("swift-syntax", location, "600.0.1")])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
    }

    @Test("a package that did not move is not aliased across organisations")
    func unmovedPackageIsNotAliased() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0002", package: "github.com/swiftlang/swift-nio",
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "3.0.0")])])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("swift-nio", "https://github.com/apple/swift-nio.git", "2.99.0")])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.isEmpty)
    }

    /// The export carries npm, Maven, Go and PyPI entries inside records that also affect a
    /// Swift package. `pubnub` on npm is not `pubnub` in a lockfile.
    @Test("an affected entry for another ecosystem is not matched by name")
    func otherEcosystemsAreIgnored() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0003", package: "swift-nio-http2", ecosystem: "npm",
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "9.0.0")])])
        let outcome = audit(
            [AdvisoryFixture.lockfile([
                .version("swift-nio-http2", "https://github.com/apple/swift-nio-http2.git", "1.43.0"),
            ])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.isEmpty)
    }

    // MARK: - Versions

    @Test("8. `last_affected` is inclusive, and says there is no fixed version", arguments: [
        ("2.1.2", true), ("2.1.3", false),
    ])
    func lastAffected(version: String, affected: Bool) throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("zip", "https://github.com/marmelroy/Zip.git", version)])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.zipTraversal]))
        #expect(outcome.findings.count == (affected ? 1 : 0))
        if affected {
            let finding = try #require(outcome.findings.first)
            #expect(finding.message.contains("Affected: <= 2.1.2; no fixed version."))
            #expect(finding.suggestedFix == "No release fixes this. Replace the dependency, or acknowledge "
                + "GHSA-g454-wj9r-jpg4 under `dependencyAudit.acknowledgedAdvisories` with a reason and an `until` date.")
        }
    }

    /// GHSA-q36x-r5x4-h4q6 is fixed in `1.20`. A matcher that cannot parse a two-component
    /// version never closes the range, and reported 1.45.0 and 1.46.0 across twelve repositories.
    @Test("9. a two-component bound is padded, not failed open")
    func twoComponentBound() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-q36x-r5x4-h4q6", package: "github.com/apple/swift-nio-http2",
            ranges: [AdvisoryFixture.range([("introduced", "1.0.0"), ("fixed", "1.20")], type: "ECOSYSTEM")])
        let lockfile = { (version: String) in
            AdvisoryFixture.lockfile([
                .version("swift-nio-http2", "https://github.com/apple/swift-nio-http2.git", version),
            ])
        }
        let snapshot = try AdvisoryFixture.candidate(records: [record])
        #expect(audit([lockfile("1.46.0")], bundled: snapshot).findings.isEmpty)
        #expect(audit([lockfile("1.19.2")], bundled: snapshot).findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
        #expect(audit([lockfile("1.20.0")], bundled: snapshot).findings.isEmpty)
    }

    @Test("10. a bound that is not a version makes the range unevaluable — not a hit, not clean")
    func unparseableBound() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0010", package: "github.com/apple/swift-nio-http2",
            ranges: [AdvisoryFixture.range([("introduced", "1.0.0"), ("fixed", "not-a-version")], type: "ECOSYSTEM")])
        let outcome = audit(
            [AdvisoryFixture.lockfile([
                .version("swift-nio-http2", "https://github.com/apple/swift-nio-http2.git", "1.46.0"),
            ])],
            bundled: try AdvisoryFixture.candidate(records: [record]))

        #expect(outcome.findings == [
            Diagnostic(
                severity: .warning,
                message: "swift-nio-http2 1.46.0 could not be compared against GHSA-test-0000-0010: "
                    + "the range bound 'not-a-version' is not a version. The advisory is neither reported nor "
                    + "cleared. Pin: github.com/apple/swift-nio-http2. Advisory data as of 2026-10-01.",
                filePath: "Package.resolved",
                lineNumber: 7,
                ruleId: "dep-advisory.unevaluable"),
        ])
        #expect(outcome.status == .warning)
    }

    @Test("11. a withdrawn record reports nothing and is counted as withdrawn")
    func withdrawnRecord() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0011", package: "github.com/apple/swift-nio",
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "3.0.0")])],
            withdrawn: "2026-08-01T00:00:00Z")
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("swift-nio", "https://github.com/apple/swift-nio.git", "2.99.0")])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.isEmpty)
        #expect(outcome.tally.withdrawnRecords == 1)
    }

    @Test("12. two disjoint ranges in one record are each evaluated", arguments: [
        ("3.15.1", false), ("4.0.0", true), ("4.2.0", true), ("4.3.1", false), ("4.5.1", false),
        ("1.0.0", true), ("2.0.0", false),
    ])
    func disjointRanges(version: String, affected: Bool) throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0012", package: "github.com/apple/swift-crypto",
            ranges: [
                AdvisoryFixture.range([("introduced", "4.0.0"), ("fixed", "4.3.1")]),
                AdvisoryFixture.range([("introduced", "0"), ("fixed", "2.0.0")]),
            ])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("swift-crypto", "https://github.com/apple/swift-crypto.git", version)])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.count == (affected ? 1 : 0))
    }

    @Test("one range with two introduced/fixed pairs is walked in order", arguments: [
        ("0.9.0", true), ("1.0.0", false), ("1.5.0", false), ("2.0.0", true), ("2.4.9", true), ("2.5.0", false),
    ])
    func multiEventRange(version: String, affected: Bool) throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0013", package: "github.com/example/pkg",
            ranges: [AdvisoryFixture.range([
                ("introduced", "0"), ("fixed", "1.0.0"), ("introduced", "2.0.0"), ("fixed", "2.5.0"),
            ])])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("pkg", "https://github.com/example/pkg.git", version)])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.count == (affected ? 1 : 0))
    }

    @Test("13. a pre-release precedes its release, so it is inside a range that release fixes")
    func preReleasePrecedesRelease() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0014", package: "github.com/example/pkg",
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "3.0.0")])])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("pkg", "https://github.com/example/pkg.git", "3.0.0-alpha.7")])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
    }

    @Test("a version listed in `affected.versions` is a hit even where no range reaches it")
    func listedVersion() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0015", package: "github.com/example/pkg",
            ranges: [AdvisoryFixture.range([("introduced", "5.0.0"), ("fixed", "5.0.1")])],
            versions: ["1.2.3"])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("pkg", "https://github.com/example/pkg.git", "1.2.3")])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
    }

    @Test("version ordering follows SemVer, with short versions padded", arguments: [
        ("1.20", "1.20.0", 0), ("1", "1.0.0", 0), ("v2.1.2", "2.1.2", 0), ("1.2.3+build.5", "1.2.3", 0),
        ("1.9.0", "1.10.0", -1), ("2.99.0", "2.100.0", -1), ("3.0.0-alpha.7", "3.0.0", -1),
        ("3.0.0-alpha.7", "3.0.0-alpha.10", -1), ("3.0.0-alpha", "3.0.0-alpha.1", -1),
        ("3.0.0-1", "3.0.0-alpha", -1), ("3.0.0-beta", "3.0.0-alpha", 1), ("600.0.1", "510.0.3", 1),
    ])
    func versionOrdering(left: String, right: String, expected: Int) throws {
        let lhs = try #require(AdvisoryVersion(left))
        let rhs = try #require(AdvisoryVersion(right))
        let actual = lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
        #expect(actual == expected)
    }

    @Test("what is not a version is not parsed as one", arguments: [
        "", "not-a-version", "1.2.3.4", "1..2", "1.x", "-1.0.0", "1.0.0-", "main",
    ])
    func notAVersion(text: String) {
        #expect(AdvisoryVersion(text) == nil)
    }

    // MARK: - Pins without versions

    @Test("14. a branch pin on a package with an advisory record is unevaluable")
    func branchPinWithRecord() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.branch("swift-nio", "https://github.com/apple/swift-nio.git", "main")])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks]))

        #expect(outcome.findings == [
            Diagnostic(
                severity: .warning,
                message: "swift-nio is pinned to branch 'main', which has no version to compare, and 1 advisory "
                    + "record names the package (GHSA-rj37-6j9x-74q6). The pin is not known to be affected and "
                    + "not known to be safe. Pin: github.com/apple/swift-nio. Advisory data as of 2026-10-01.",
                filePath: "Package.resolved",
                lineNumber: 7,
                ruleId: "dep-advisory.unevaluable"),
        ])
    }

    @Test("15. a branch pin on a package with no record is silent, and counted as unevaluable")
    func branchPinWithoutRecord() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.branch("indexstore-db", "https://github.com/apple/indexstore-db.git", "main")])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks]))
        #expect(outcome.findings.isEmpty)
        #expect(outcome.tally.unevaluablePins == 1)
        #expect(outcome.tally.evaluablePins == 0)
    }

    @Test("16. a revision-only pin on a package with a record is unevaluable")
    func revisionPinWithRecord() throws {
        let outcome = audit(
            [AdvisoryFixture.lockfile([.revision("swift-nio", "https://github.com/apple/swift-nio.git")])],
            bundled: try AdvisoryFixture.candidate(records: [AdvisoryFixture.nioHeaderBlocks]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.unevaluable"])
        #expect(outcome.findings.first?.message.hasPrefix(
            "swift-nio is pinned to a bare revision, which has no version to compare, and 1 advisory record") == true)
    }

    // MARK: - Severity

    /// CRITICAL and HIGH gate from the first day (`TheGateIsNotYetAggressive.md`, Phase 1).
    /// MODERATE arrives as a warning and is an error at the proposal's destination; see
    /// `AdvisorySeverity.moderate`.
    @Test("17. severity follows GitHub's label", arguments: [
        ("CRITICAL", Diagnostic.Severity.error), ("HIGH", .error), ("MODERATE", .warning), ("LOW", .warning),
        ("high", .error),
    ])
    func severityFromLabel(label: String, expected: Diagnostic.Severity) throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0017", severity: label, package: "github.com/example/pkg",
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "2.0.0")])])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("pkg", "https://github.com/example/pkg.git", "1.0.0")])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.map(\.severity) == [expected])
    }

    /// Fourteen records carry a CVSS v4 vector, whose base score is a table lookup the gate would
    /// have to carry and keep right to arrive at a label it has already been given.
    @Test("18. a CVSS vector with no label is a warning, and the vector is quoted, not scored")
    func vectorWithoutLabel() throws {
        let vector = "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N"
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0018", severity: nil, cvss: ("CVSS_V4", vector),
            package: "github.com/example/pkg",
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "2.0.0")])])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("pkg", "https://github.com/example/pkg.git", "1.0.0")])],
            bundled: try AdvisoryFixture.candidate(records: [record]))

        let finding = try #require(outcome.findings.first)
        #expect(outcome.findings.count == 1)
        #expect(finding.severity == .warning)
        #expect(finding.message == "pkg 1.0.0 is affected by GHSA-test-0000-0018 (no severity recorded; \(vector)): "
            + "A test advisory. Affected: < 2.0.0; fixed in 2.0.0. Pin: github.com/example/pkg. "
            + "Advisory data as of 2026-10-01. [CWE-1395]")
    }

    @Test("no severity and no vector is still a warning")
    func noSeverityAtAll() throws {
        let record = AdvisoryFixture.record(
            id: "GHSA-test-0000-0019", severity: nil, package: "github.com/example/pkg",
            ranges: [AdvisoryFixture.range([("introduced", "0"), ("fixed", "2.0.0")])])
        let outcome = audit(
            [AdvisoryFixture.lockfile([.version("pkg", "https://github.com/example/pkg.git", "1.0.0")])],
            bundled: try AdvisoryFixture.candidate(records: [record]))
        #expect(outcome.findings.map(\.severity) == [.warning])
        #expect(outcome.findings.first?.message.contains("(no severity recorded):") == true)
    }

    // MARK: - Location

    @Test("each finding is reported at its own pin's line, in its own lockfile")
    func findingsCarryTheirLocation() throws {
        let root = AdvisoryFixture.lockfile([
            .version("swift-syntax", "https://github.com/swiftlang/swift-syntax.git", "600.0.1"),
            .version("swift-nio", "https://github.com/apple/swift-nio.git", "2.99.0"),
        ])
        let nested = AdvisoryFixture.lockfile(
            [.version("zip", "https://github.com/marmelroy/Zip.git", "2.1.2")],
            path: "Tools/helper/Package.resolved")
        let outcome = audit(
            [root, nested],
            bundled: try AdvisoryFixture.candidate(
                records: [AdvisoryFixture.nioHeaderBlocks, AdvisoryFixture.zipTraversal]))

        #expect(outcome.findings.map(\.filePath) == ["Package.resolved", "Tools/helper/Package.resolved"])
        #expect(outcome.findings.map(\.lineNumber) == [15, 7])
    }
}
