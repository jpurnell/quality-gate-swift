import Foundation
import Testing
@testable import QualityGateCore
@testable import ReleaseReadinessAuditor

/// The release-tag invariant, split into the three questions it was conflating.
@Suite("Release Tag Invariant")
struct ReleaseTagInvariantTests {

    // MARK: - Parity, and where it is allowed to bite

    @Test("On a normal run an untagged version is a note, so the gate stays satisfiable")
    func untaggedIsAdvisoryOnANormalRun() throws {
        // The workflow is gate-green-then-commit, and a tag names a commit that does not exist
        // yet. As an error this rule could only be satisfied by inverting the project's own
        // order at exactly the moment a release is being cut — which trains the `--no-verify`
        // reflex the project forbids. It is still reported, just without a veto.
        let findings = ReleaseTagInvariant.parity(
            version: "0.1.1", tags: ["v0.1.0"], isBoundary: false)

        let finding = try #require(findings.first)
        #expect(finding.severity == .note)
        #expect(finding.ruleId == "release-untagged-version")
    }

    @Test("At a push boundary the same finding is an error")
    func untaggedIsAnErrorAtTheBoundary() throws {
        // Push is where the failure becomes visible to consumers, and where a tag can exist.
        let findings = ReleaseTagInvariant.parity(
            version: "0.1.1", tags: ["v0.1.0"], isBoundary: true)

        #expect(try #require(findings.first).severity == .error)
    }

    @Test("A tagged version is silent in both modes")
    func taggedVersionPasses() {
        #expect(ReleaseTagInvariant.parity(
            version: "0.1.1", tags: ["v0.1.1"], isBoundary: true).isEmpty)
        #expect(ReleaseTagInvariant.parity(
            version: "0.1.1", tags: ["0.1.1"], isBoundary: false).isEmpty)
    }

    @Test("Monorepo tag prefixes still normalise on both sides")
    func monorepoPrefixNormalises() {
        #expect(ReleaseTagInvariant.parity(
            version: "0.1.0", tags: ["IconquerApp@v0.1.0"], isBoundary: true).isEmpty)
    }

    // MARK: - Identity: the tag must contain what it claims

    @Test("Publishing a tag whose tree does not document the version is an error")
    func publishingAMismatchedTagIsAnError() throws {
        // `git tag v9.9.9 <any-old-commit>` satisfied the old name-membership test while the
        // tagged tree contained no such release. Consumers resolving that tag get a package
        // that never mentions the version they asked for.
        let findings = ReleaseTagInvariant.identity(
            version: "9.9.9", tag: "v9.9.9",
            changelogAtTag: "# Changelog\n\n## [0.1.0] — 2026-01-01\n",
            isPublishing: true)

        let finding = try #require(findings.first)
        #expect(finding.severity == .error)
        #expect(finding.ruleId == "release-tag-content-mismatch")
    }

    @Test("A historical mismatch is reported, not blocked on")
    func historicalMismatchIsANote() throws {
        // This repository's own `v2.0.2` is the case: tagged before its CHANGELOG entry was
        // written, so the tagged tree documents `[Unreleased]`, `[2026.07.12]`, `[2026.07.10]`
        // and never mentions 2.0.2. The finding is true, and the only remedy is moving a tag
        // that is already on the remote — a rule whose fix is rewriting published history is
        // unsatisfiable in exactly the way the commit-time parity rule was.
        let findings = ReleaseTagInvariant.identity(
            version: "2.0.2", tag: "v2.0.2",
            changelogAtTag: "# Changelog\n\n## [Unreleased]\n\n## [2026.07.12] — 2026-07-12\n",
            isPublishing: false)

        let finding = try #require(findings.first)
        #expect(finding.severity == .note)
        #expect(finding.ruleId == "release-tag-content-mismatch")
    }

    @Test("A tag whose tree documents the version passes")
    func matchingTagPasses() {
        #expect(ReleaseTagInvariant.identity(
            version: "0.1.1", tag: "v0.1.1",
            changelogAtTag: "# Changelog\n\n## [0.1.1] — 2026-08-12\n",
            isPublishing: true).isEmpty)
    }

    @Test("An unreadable tagged CHANGELOG is not evidence of a mismatch")
    func unreadableChangelogIsNotAFinding() {
        // A shallow clone, or a tag on a commit predating the file, means the fact is absent
        // rather than false. Reporting a mismatch here would be inventing one.
        #expect(ReleaseTagInvariant.identity(
            version: "0.1.1", tag: "v0.1.1", changelogAtTag: nil, isPublishing: true).isEmpty)
    }

    // MARK: - The boundary: is the tag actually going out?

    @Test("A tag in this push satisfies the boundary without touching the network")
    func tagInThisPushPasses() {
        let refs = PushedRefs.parse("""
        refs/heads/main aaaa111 refs/heads/main bbbb222
        refs/tags/v0.1.1 cccc333 refs/tags/v0.1.1 0000000000000000000000000000000000000000
        """)

        #expect(ReleaseTagInvariant.boundary(
            version: "0.1.1", tags: ["v0.1.1"], pushedRefs: refs, remoteHasTag: { _ in
                Issue.record("the remote must not be consulted when the tag is in the push")
                return false
            }).isEmpty)
    }

    @Test("A tag that exists locally but is not being pushed and is not on the remote errors")
    func localOnlyTagIsCaught() throws {
        // The 2026-07-06 failure with a green gate on top of it: tagged, never pushed,
        // consumers still cannot resolve the release.
        let refs = PushedRefs.parse("refs/heads/main aaaa111 refs/heads/main bbbb222")

        let findings = ReleaseTagInvariant.boundary(
            version: "0.1.1", tags: ["v0.1.1"], pushedRefs: refs, remoteHasTag: { _ in false })

        let finding = try #require(findings.first)
        #expect(finding.severity == .error)
        #expect(finding.ruleId == "release-tag-unpushed")
    }

    @Test("A tag already on the remote satisfies the boundary even when this push omits it")
    func tagAlreadyOnRemotePasses() {
        let refs = PushedRefs.parse("refs/heads/main aaaa111 refs/heads/main bbbb222")

        #expect(ReleaseTagInvariant.boundary(
            version: "0.1.1", tags: ["v0.1.1"], pushedRefs: refs, remoteHasTag: { _ in true })
            .isEmpty)
    }

    @Test("Deleting a tag does not count as pushing it")
    func tagDeletionDoesNotSatisfyTheBoundary() throws {
        let refs = PushedRefs.parse(
            "refs/tags/v0.1.1 0000000000000000000000000000000000000000 refs/tags/v0.1.1 cccc333")

        let findings = ReleaseTagInvariant.boundary(
            version: "0.1.1", tags: ["v0.1.1"], pushedRefs: refs, remoteHasTag: { _ in false })

        #expect(try #require(findings.first).ruleId == "release-tag-unpushed")
    }

    @Test("With no tag at all the boundary says nothing — parity already did")
    func boundaryIsSilentWhenThereIsNoTag() {
        // Two rules reporting one cause is noise. `release-untagged-version` owns "no tag".
        #expect(ReleaseTagInvariant.boundary(
            version: "0.1.1", tags: [], pushedRefs: nil, remoteHasTag: { _ in false }).isEmpty)
    }
}
