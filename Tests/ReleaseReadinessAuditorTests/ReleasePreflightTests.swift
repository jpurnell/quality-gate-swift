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

    @Test("A project that declares no version has nothing to disagree with")
    func silentWhenProjectDeclaresNoVersion() {
        // The bug this replaces: `release` passed quality-gate's OWN --version as the surveyed
        // project's declared version, so every library it was ever run against was told "the CLI
        // reports version 3.1.0" — a number from the auditing tool, about the audited package.
        // A library declares no CLI version, so there is nothing to compare and nothing to say.
        #expect(ReleasePreflight.versionParity(
            declaredVersion: nil, changelogVersion: "0.1.2", candidateTag: "v0.1.2").isEmpty)
    }

    @Test("A tag mismatch is still caught when no version is declared")
    func tagStillCheckedWithoutDeclaredVersion() throws {
        // Silence about the declared version must not silence the tag check beside it.
        let findings = ReleasePreflight.versionParity(
            declaredVersion: nil, changelogVersion: "0.1.2", candidateTag: "v0.9.9")

        #expect(try #require(findings.first).ruleId == "release.tag-mismatch")
    }

    // MARK: - Declared version detection

    @Test("The declared version is read from the surveyed project, not from this tool")
    func declaredVersionComesFromTheSurveyedProject() throws {
        let root = try TemporaryProject(sources: [
            "Thing/Thing.swift": """
            public enum Thing {
                public static let version = "0.1.2"
            }
            """
        ])
        defer { root.remove() }

        #expect(ReleasePreflight.declaredVersion(inProjectAt: root.path) == "0.1.2")
    }

    @Test("An ArgumentParser command's version is a declared version")
    func declaredVersionFromCommandConfiguration() throws {
        let root = try TemporaryProject(sources: [
            "CLI/CLI.swift": """
            static let configuration = CommandConfiguration(
                commandName: "thing",
                version: "3.1.0",
                subcommands: [])
            """
        ])
        defer { root.remove() }

        #expect(ReleasePreflight.declaredVersion(inProjectAt: root.path) == "3.1.0")
    }

    @Test("An unrelated schema version is not the project's version")
    func schemaVersionIsNotTheProjectVersion() throws {
        // SARIFReporter assigns `self.version = "2.1.0"` — the SARIF schema's version. Reading
        // that as the project's would report a mismatch against a number the project never claimed.
        let root = try TemporaryProject(sources: [
            "Reporters/SARIFReporter.swift": """
            init() {
                self.version = "2.1.0"
            }
            """
        ])
        defer { root.remove() }

        #expect(ReleasePreflight.declaredVersion(inProjectAt: root.path) == nil)
    }

    @Test("A project stating no version anywhere reads as absent, not as zero")
    func noDeclaredVersionAnywhere() throws {
        let root = try TemporaryProject(sources: [
            "Thing/Thing.swift": "public enum Thing {}"
        ])
        defer { root.remove() }

        #expect(ReleasePreflight.declaredVersion(inProjectAt: root.path) == nil)
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


/// A throwaway `Sources/` tree, so the scanner can be tested against a project that is not this one.
private struct TemporaryProject {
    let path: String

    init(sources: [String: String]) throws {
        let root = NSTemporaryDirectory() + "qg-preflight-" + UUID().uuidString
        self.path = root
        for (relative, contents) in sources {
            let full = ((root as NSString).appendingPathComponent("Sources") as NSString)
                .appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (full as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
