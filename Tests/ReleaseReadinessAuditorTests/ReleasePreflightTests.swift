import Foundation
import Testing
@testable import QualityGateCore
@testable import ReleaseReadinessAuditor

/// The release-scoped observer — §9.4's first item, and the one the design called *"most likely
/// to be forgotten, because it is the only item that is not a checker."*
@Suite("Release Preflight")
struct ReleasePreflightTests {

    // MARK: - Version parity

    @Test("Three documents stating one version must agree")
    func versionsMustAgree() throws {
        // Measured on 2026-08-12, before this existed: the CLI said 2.0.1, the CHANGELOG's
        // newest release said 2.0.2, the newest tag said v2.0.2, and the maintainer said "about
        // 2.6". Four answers, because each document drifts alone and nothing compares them.
        let findings = ReleasePreflight.versionParity(
            declaredVersion: "2.0.1", changelogVersion: "2.0.2", candidateTag: nil)

        let finding = try #require(findings.first)
        #expect(finding.ruleId == "release.version-mismatch")
        #expect(finding.message.contains("2.0.1"))
        #expect(finding.message.contains("2.0.2"))
    }

    @Test("Agreement is silent")
    func agreementIsSilent() {
        #expect(ReleasePreflight.versionParity(
            declaredVersion: "3.0.0", changelogVersion: "3.0.0", candidateTag: "v3.0.0").isEmpty)
    }

    @Test("A `v` prefix is spelling, not disagreement")
    func tagPrefixIsNotDisagreement() {
        #expect(ReleasePreflight.versionParity(
            declaredVersion: "3.0.0", changelogVersion: "3.0.0", candidateTag: "v3.0.0").isEmpty)
        #expect(ReleasePreflight.versionParity(
            declaredVersion: "3.0.0", changelogVersion: "3.0.0",
            candidateTag: "QualityGate@v3.0.0").isEmpty)
    }

    @Test("A candidate tag naming a different version is caught")
    func candidateTagMustMatch() throws {
        let findings = ReleasePreflight.versionParity(
            declaredVersion: "3.0.0", changelogVersion: "3.0.0", candidateTag: "v2.9.0")

        #expect(try #require(findings.first).ruleId == "release.tag-mismatch")
    }

    @Test("Releasing with no documented version at all is the first thing to say")
    func noDocumentedVersion() throws {
        let findings = ReleasePreflight.versionParity(
            declaredVersion: "3.0.0", changelogVersion: nil, candidateTag: nil)

        #expect(try #require(findings.first).ruleId == "release.no-documented-version")
    }

    // MARK: - Unreleased

    @Test("Content left under [Unreleased] is the release documenting itself as unshipped")
    func unreleasedMustBeEmpty() throws {
        let findings = ReleasePreflight.unreleasedIsEmpty(changelog: """
        # Changelog

        ## [Unreleased]

        - A thing that shipped in this very release.
        - Another.

        ## [2.0.2] — 2026-07-27
        """)

        let finding = try #require(findings.first)
        #expect(finding.ruleId == "release.unreleased-not-empty")
        #expect(finding.message.contains("2"))
    }

    @Test("An empty Unreleased section passes")
    func emptyUnreleasedPasses() {
        #expect(ReleasePreflight.unreleasedIsEmpty(changelog: """
        # Changelog

        ## [Unreleased]

        ## [3.0.0] — 2026-08-12

        - The release.
        """).isEmpty)
    }

    @Test("A changelog with no Unreleased section at all passes")
    func absentUnreleasedPasses() {
        #expect(ReleasePreflight.unreleasedIsEmpty(changelog: """
        # Changelog

        ## [3.0.0] — 2026-08-12

        - The release.
        """).isEmpty)
    }

    // MARK: - Reading the dates

    @Test("The newest dated release heading wins, and [Unreleased] is not one")
    func newestReleaseDateSkipsUnreleased() throws {
        let date = try #require(ReleasePreflight.newestReleaseDate(in: """
        # Changelog

        ## [Unreleased]

        ## [3.0.0] — 2026-08-12

        ## [2.0.2] — 2026-07-27
        """))

        #expect(ReleasePreflight.isoDate(in: "2026-08-12") == date)
    }

    @Test("An undated changelog yields no date rather than a guess")
    func undatedChangelogYieldsNothing() {
        #expect(ReleasePreflight.newestReleaseDate(in: "# Changelog\n\n## [3.0.0]\n") == nil)
    }

    @Test("The plan's Last Updated line is read")
    func planLastUpdatedIsRead() throws {
        let date = try #require(ReleasePreflight.lastUpdated(
            inPlan: "# Plan\n\n**Last Updated:** 2026-06-04\n"))

        #expect(ReleasePreflight.isoDate(in: "2026-06-04") == date)
    }

    @Test("A plan with no Last Updated line yields no date")
    func planWithoutLastUpdated() {
        #expect(ReleasePreflight.lastUpdated(inPlan: "# Plan\n\nNo date here.\n") == nil)
    }

    // MARK: - The temporal question, asked where it is legitimate

    @Test("A plan last updated before the release it ships with was not reconciled")
    func planMustBeReconciled() throws {
        // This is the whole point of §9.4. At commit time the hermeticity contract clamps
        // staleness to a note — correctly, since the calendar is not the commit's fault. Here
        // nothing is being blamed on a commit: the release *is* the calendar event, so the
        // question can be asked with authority for the first time.
        let plan = Date(timeIntervalSince1970: 1_750_000_000)
        let release = plan.addingTimeInterval(86_400 * 30)

        let findings = ReleasePreflight.planReconciled(
            planLastUpdated: plan, releaseDate: release)

        #expect(try #require(findings.first).ruleId == "release.plan-not-reconciled")
    }

    @Test("A plan updated with the release passes")
    func reconciledPlanPasses() {
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        #expect(ReleasePreflight.planReconciled(
            planLastUpdated: when, releaseDate: when).isEmpty)
        #expect(ReleasePreflight.planReconciled(
            planLastUpdated: when.addingTimeInterval(3600), releaseDate: when).isEmpty)
    }

    @Test("An absent date is not evidence of neglect")
    func missingDatesAreNotFindings() {
        // A plan with no `Last Updated` line, or a heading with no date, means the fact cannot
        // be established. Inventing a finding from missing evidence gives the reader something
        // unfixable, which is the failure mode the identity rule already had to be narrowed for.
        #expect(ReleasePreflight.planReconciled(planLastUpdated: nil, releaseDate: Date()).isEmpty)
        #expect(ReleasePreflight.planReconciled(planLastUpdated: Date(), releaseDate: nil).isEmpty)
    }
}
