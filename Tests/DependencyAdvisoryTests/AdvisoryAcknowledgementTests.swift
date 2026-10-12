import Foundation
import Testing
import QualityGateCore
@testable import DependencyAdvisory

/// Acknowledging an advisory that does not apply.
///
/// `Package.resolved` is JSON; there is no line above it to carry a comment. So the
/// acknowledgement lives in `.quality-gate.yml`, names the advisory and the package, gives a
/// reason held to the same standard as any other justification in the gate, and expires — against
/// the snapshot's date, not the wall clock, so the same tree gives the same answer on any day.
@Suite("dependency-advisory: acknowledgement")
struct AdvisoryAcknowledgementTests {

    private typealias Pin = AdvisoryFixture.Pin

    private static let reason = "Transitive via polar-ble-sdk. No code path here extracts an archive."

    private let zip = AdvisoryFixture.lockfile([
        .version("zip", "https://github.com/marmelroy/Zip.git", "2.1.2"),
    ])

    private func run(
        _ acknowledgements: [AcknowledgedAdvisory], fetched: String = "2026-10-01"
    ) throws -> AdvisoryAuditOutcome {
        audit(
            [zip],
            bundled: try AdvisoryFixture.candidate(fetched: fetched, records: [AdvisoryFixture.zipTraversal]),
            configuration: DependencyAuditorConfig(acknowledgedAdvisories: acknowledgements))
    }

    @Test("24. a matching id and package, a real reason and a live `until` records an override and reports nothing")
    func accepted() throws {
        let outcome = try run([
            AcknowledgedAdvisory(
                id: "GHSA-g454-wj9r-jpg4", package: "github.com/marmelroy/Zip",
                reason: Self.reason, until: "2027-01-01"),
        ])

        #expect(outcome.findings.isEmpty)
        #expect(outcome.overrides == [
            DiagnosticOverride(
                ruleId: "dep-advisory.vulnerable-pin",
                justification: "GHSA-g454-wj9r-jpg4 on github.com/marmelroy/Zip, acknowledged until 2027-01-01: "
                    + Self.reason,
                filePath: "Package.resolved",
                lineNumber: 7),
        ])
        #expect(outcome.status == .passed)
        #expect(outcome.diagnostics.last?.message.contains("1 affected by 1 advisory · 1 acknowledged") == true)
    }

    @Test("the acknowledgement may name the CVE alias, and the package in any case or URL form")
    func acceptedByAlias() throws {
        let outcome = try run([
            AcknowledgedAdvisory(
                id: "cve-2023-39135", package: "https://github.com/Marmelroy/zip.git",
                reason: Self.reason, until: "2027-01-01"),
        ])
        #expect(outcome.findings.isEmpty)
        #expect(outcome.overrides.count == 1)
    }

    @Test("25. an acknowledgement without a real reason is not accepted, and the finding says why", arguments: [
        ("", "it gives no reason"),
        ("   ", "it gives no reason"),
        ("not reachable here", "its reason has 3 words and 8 are required"),
        ("safe", "its reason is the stock phrase 'safe'"),
    ])
    func rejectedReason(reason: String, why: String) throws {
        let outcome = try run([
            AcknowledgedAdvisory(
                id: "GHSA-g454-wj9r-jpg4", package: "github.com/marmelroy/Zip", reason: reason, until: "2027-01-01"),
        ])

        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
        #expect(outcome.findings.first?.severity == .error)
        #expect(outcome.findings.first?.message.hasSuffix(
            "[CWE-1395] (the acknowledgement in `dependencyAudit.acknowledgedAdvisories` was not accepted: \(why))") == true)
        #expect(outcome.overrides.isEmpty)
    }

    @Test("an acknowledgement must carry an `until` date, in a form that can be compared", arguments: [
        ("", "it has no `until` date"),
        ("01/01/2027", "its `until` date '01/01/2027' is not YYYY-MM-DD"),
        ("2027-13-45", "its `until` date '2027-13-45' is not YYYY-MM-DD"),
    ])
    func rejectedUntil(until: String, why: String) throws {
        let outcome = try run([
            AcknowledgedAdvisory(
                id: "GHSA-g454-wj9r-jpg4", package: "github.com/marmelroy/Zip", reason: Self.reason, until: until),
        ])
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin"])
        #expect(outcome.findings.first?.message.hasSuffix("was not accepted: \(why))") == true)
    }

    @Test("26. an acknowledgement expires when the snapshot's date reaches `until`, and the finding returns", arguments: [
        ("2026-10-01", "2026-10-01", true),
        ("2026-10-02", "2026-10-01", true),
        ("2026-09-30", "2026-10-01", false),
    ])
    func expiry(fetched: String, until: String, expired: Bool) throws {
        let outcome = try run(
            [AcknowledgedAdvisory(
                id: "GHSA-g454-wj9r-jpg4", package: "github.com/marmelroy/Zip", reason: Self.reason, until: until)],
            fetched: fetched)

        guard expired else {
            #expect(outcome.findings.isEmpty)
            return
        }
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.vulnerable-pin", "dep-advisory.acknowledgement-expired"])
        #expect(outcome.findings.last == Diagnostic(
            severity: .warning,
            message: "The acknowledgement of GHSA-g454-wj9r-jpg4 for github.com/marmelroy/Zip expired on "
                + "\(until): the advisory snapshot in use was fetched \(fetched). The finding is reported again — "
                + "fix the pin, or renew the acknowledgement with a reason that is still true.",
            filePath: ".quality-gate.yml",
            ruleId: "dep-advisory.acknowledgement-expired"))
        #expect(outcome.overrides.isEmpty)
        #expect(outcome.status == .failed)
    }

    @Test("27. an acknowledgement no finding matches is reported — a stale exemption is how the next one gets copied")
    func unused() throws {
        let outcome = try run([
            AcknowledgedAdvisory(
                id: "GHSA-g454-wj9r-jpg4", package: "github.com/marmelroy/Zip",
                reason: Self.reason, until: "2027-01-01"),
            AcknowledgedAdvisory(
                id: "GHSA-rj37-6j9x-74q6", package: "github.com/apple/swift-nio",
                reason: Self.reason, until: "2027-01-01"),
        ])

        #expect(outcome.findings == [
            Diagnostic(
                severity: .warning,
                message: "`dependencyAudit.acknowledgedAdvisories` acknowledges GHSA-rj37-6j9x-74q6 for "
                    + "github.com/apple/swift-nio, and no pin here is affected by it. Remove the entry.",
                filePath: ".quality-gate.yml",
                ruleId: "dep-advisory.acknowledgement-unused"),
        ])
        #expect(outcome.status == .warning)
    }

    @Test("the right advisory for the wrong package acknowledges nothing")
    func packageMustMatch() throws {
        let outcome = try run([
            AcknowledgedAdvisory(
                id: "GHSA-g454-wj9r-jpg4", package: "github.com/someone/Zip",
                reason: Self.reason, until: "2027-01-01"),
        ])
        #expect(outcome.findings.map(\.ruleId) == [
            "dep-advisory.vulnerable-pin", "dep-advisory.acknowledgement-unused",
        ])
    }

    @Test("with no snapshot, an acknowledgement is not called unused — nothing was compared")
    func unusedNeedsASnapshot() {
        let outcome = audit(
            [zip],
            configuration: DependencyAuditorConfig(acknowledgedAdvisories: [
                AcknowledgedAdvisory(
                    id: "GHSA-g454-wj9r-jpg4", package: "github.com/marmelroy/Zip",
                    reason: Self.reason, until: "2027-01-01"),
            ]))
        #expect(outcome.findings.map(\.ruleId) == ["dep-advisory.no-snapshot"])
    }
}
