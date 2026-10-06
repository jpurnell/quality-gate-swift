import Foundation
import Testing
import QualityGateCore
@testable import DependencyAdvisory

/// How old the knowledge is.
///
/// `dependency-advisory` is deterministic because it does not look at the clock, which means a
/// commit can be green and vulnerable for as long as the snapshot is stale. This checker is the
/// one that says so. It is `.temporal`, so by default it reports a note and cannot fail a build
/// that did nothing wrong but be checked late.
@Suite("dependency-advisory-freshness")
struct AdvisoryFreshnessTests {

    private typealias Pin = AdvisoryFixture.Pin

    private func project() throws -> AdvisoryTestProject {
        let project = try AdvisoryTestProject()
        try project.write(
            AdvisoryFixture.lockfileText([
                .version("swift-nio", "https://github.com/apple/swift-nio.git", "2.103.0"),
                .version("swift-syntax", "https://github.com/swiftlang/swift-syntax.git", "600.0.1"),
            ]),
            to: "Package.resolved")
        return project
    }

    private func run(
        fetched: String, today: String, maxAge: Int = 14, includeNonHermetic: Bool = false
    ) async throws -> CheckResult {
        let project = try project()
        defer { project.remove() }
        let checker = AdvisoryFreshnessChecker(environment: .fixed(
            bundled: try AdvisoryFixture.candidate(fetched: fetched, records: [AdvisoryFixture.nioHeaderBlocks]),
            today: today))
        let results = await CheckerRunner().run(
            checkers: [checker],
            configuration: project.configuration(DependencyAuditorConfig(advisorySnapshotMaxAgeDays: maxAge)),
            strict: false, continueOnFailure: true, includeNonHermetic: includeNonHermetic).results
        return try #require(results.first)
    }

    private static let stale = "The advisory snapshot (bundled) was fetched 2026-09-06, 30 days before 2026-10-06; "
        + "the maximum is 14. 2 pins in 1 lockfile were checked only against advisories known on 2026-09-06 — "
        + "nothing published since has been checked. Run `quality-gate advisories refresh`, or upgrade the gate "
        + "for a newer bundled snapshot."

    @Test("28. a snapshot 30 days old is reported as a note, and the run passes")
    func staleIsANote() async throws {
        let result = try await run(fetched: "2026-09-06", today: "2026-10-06")
        #expect(result.status == .passed)
        #expect(result.diagnostics == [
            Diagnostic(severity: .note, message: Self.stale, ruleId: "dep-advisory.snapshot-stale"),
        ])
    }

    @Test("29. with --include-nonhermetic the same finding is an error, and the run fails")
    func staleFailsWhenAskedTo() async throws {
        let result = try await run(fetched: "2026-09-06", today: "2026-10-06", includeNonHermetic: true)
        #expect(result.status == .failed)
        #expect(result.diagnostics == [
            Diagnostic(severity: .error, message: Self.stale, ruleId: "dep-advisory.snapshot-stale"),
        ])
    }

    @Test("the threshold is the configured maximum, exclusive", arguments: [
        ("2026-09-22", 14, false), ("2026-09-21", 14, true), ("2026-09-06", 30, false), ("2026-10-06", 0, false),
        ("2026-10-05", 0, true),
    ])
    func threshold(fetched: String, maxAge: Int, stale: Bool) async throws {
        let result = try await run(fetched: fetched, today: "2026-10-06", maxAge: maxAge, includeNonHermetic: true)
        #expect(result.diagnostics.map(\.ruleId) == [stale ? "dep-advisory.snapshot-stale" : "dep-advisory.snapshot-age"])
        #expect(result.status == (stale ? .failed : .passed))
    }

    @Test("a snapshot within the maximum still says how old it is")
    func freshSaysItsAge() async throws {
        let result = try await run(fetched: "2026-10-01", today: "2026-10-06")
        #expect(result.status == .passed)
        #expect(result.diagnostics == [
            Diagnostic(
                severity: .note,
                message: "The advisory snapshot (bundled) was fetched 2026-10-01, 5 days before 2026-10-06 "
                    + "(maximum 14).",
                ruleId: "dep-advisory.snapshot-age"),
        ])
    }

    @Test("a snapshot dated after today is not stale, and is not given a negative age")
    func snapshotFromTomorrow() async throws {
        let result = try await run(fetched: "2026-10-07", today: "2026-10-06", includeNonHermetic: true)
        #expect(result.status == .passed)
        #expect(result.diagnostics.first?.message == "The advisory snapshot (bundled) was fetched 2026-10-07, "
            + "0 days before 2026-10-06 (maximum 14).")
    }

    @Test("with no snapshot there is no age to report, and the run says so instead of passing")
    func noSnapshot() async throws {
        let project = try project()
        defer { project.remove() }
        let result = try await AdvisoryFreshnessChecker(environment: .fixed(bundled: nil))
            .check(configuration: project.configuration())
        #expect(result.status == .skipped)
        #expect(result.diagnostics == [
            Diagnostic(
                severity: .note,
                message: "No usable advisory snapshot, so there is no age to report; `dependency-advisory` "
                    + "reports the 2 pins that were not checked.",
                ruleId: "dep-advisory.snapshot-age"),
        ])
    }

    @Test("the day is the UTC day, whatever the hour", arguments: [
        (0.0, "1970-01-01"), (86_399.0, "1970-01-01"), (86_400.0, "1970-01-02"),
        (1_791_244_800.0, "2026-10-06"), (1_791_331_199.0, "2026-10-06"), (951_782_400.0, "2000-02-29"),
    ])
    func utcDay(seconds: Double, expected: String) {
        #expect(AdvisoryDate(utcDateOf: Date(timeIntervalSince1970: seconds)).text == expected)
    }

    @Test("dates count days across months, years and leap days", arguments: [
        ("2026-09-06", "2026-10-06", 30), ("2026-12-31", "2027-01-01", 1), ("2024-02-28", "2024-03-01", 2),
        ("2025-02-28", "2025-03-01", 1), ("2026-10-06", "2026-10-06", 0),
    ])
    func dayArithmetic(from: String, to: String, days: Int) throws {
        let start = try #require(AdvisoryDate(from))
        let end = try #require(AdvisoryDate(to))
        #expect(end.dayNumber - start.dayNumber == days)
    }

    @Test("what is not a calendar date is not parsed as one", arguments: [
        "", "2026-13-01", "2026-02-30", "2025-02-29", "26-10-06", "2026/10/06", "2026-10-6", "last Tuesday",
    ])
    func notADate(text: String) {
        #expect(AdvisoryDate(text) == nil)
    }
}
