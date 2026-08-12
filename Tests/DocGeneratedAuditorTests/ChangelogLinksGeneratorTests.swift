import Foundation
import Testing
@testable import DocGeneratedAuditor
@testable import QualityGateCore

/// Generator tests, kept separate from checker tests so a generator defect is
/// distinguishable from a comparison defect.
@Suite("Changelog Links Generator")
struct ChangelogLinksGeneratorTests {

    /// The shape this repository's own CHANGELOG has: bracketed headings on top, and older
    /// unbracketed ones below that were written before the convention arrived.
    private static let changelog = """
    # Changelog

    ## [Unreleased]

    - Something not yet released.

    ## [2.0.2] — 2026-07-27

    - A release.

    ## [2026.07.12] — 2026-07-12

    - An earlier release.

    ## 2.0.1

    - Written before the bracket convention.

    ## 1.0.0

    - The first one.
    """

    private static func configuration(
        repositoryURL: String? = "https://github.com/jpurnell/quality-gate-swift",
        tagPrefix: String = ""
    ) -> Configuration {
        TemporaryDocProject.configuration(
            docGenerated: DocGeneratedConfig(repositoryURL: repositoryURL, tagPrefix: tagPrefix))
    }

    @Test("Identity: the id in the delimiters, and a source a reader can go and check")
    func identity() {
        let generator = ChangelogLinksGenerator()
        #expect(generator.id == "changelog-links")
        #expect(generator.derivedFrom.contains("CHANGELOG.md"))
    }

    @Test("One definition per bracketed heading, newest first, chained as compare links")
    func compareChain() throws {
        let root = try TemporaryDocProject.make(changelog: Self.changelog)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ChangelogLinksGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Self.configuration())

        let base = "https://github.com/jpurnell/quality-gate-swift"
        #expect(body.lines == [
            "[Unreleased]: \(base)/compare/2.0.2...HEAD",
            "[2.0.2]: \(base)/compare/2026.07.12...2.0.2",
            "[2026.07.12]: \(base)/compare/2.0.1...2026.07.12",
        ])
    }

    @Test("An unbracketed heading is a link nobody wrote, so it anchors a chain and gets no row")
    func unbracketedHeadingsChainButAreNotDefined() throws {
        let root = try TemporaryDocProject.make(changelog: Self.changelog)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ChangelogLinksGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Self.configuration())

        // `2.0.1` is the real predecessor of `2026.07.12` and appears in that compare link,
        // but no `[2.0.1]:` definition exists — nothing in the document references it.
        #expect(body.contains("2.0.1...2026.07.12"))
        #expect(!body.contains("[2.0.1]:"))
        #expect(!body.contains("[1.0.0]:"))
    }

    @Test("The oldest heading has nothing to compare against, so it points at its tag")
    func oldestPointsAtItsTag() throws {
        let root = try TemporaryDocProject.make(changelog: """
        # Changelog

        ## [1.1.0] — 2026-01-02

        ## [1.0.0] — 2026-01-01
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ChangelogLinksGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Self.configuration())

        let base = "https://github.com/jpurnell/quality-gate-swift"
        #expect(body.lines == [
            "[1.1.0]: \(base)/compare/1.0.0...1.1.0",
            "[1.0.0]: \(base)/releases/tag/1.0.0",
        ])
    }

    @Test("Unreleased with no release behind it compares against nothing, so it lists commits")
    func unreleasedAlone() throws {
        let root = try TemporaryDocProject.make(changelog: """
        # Changelog

        ## [Unreleased]

        - The first thing, not yet shipped.
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ChangelogLinksGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Self.configuration())

        #expect(body == "[Unreleased]: https://github.com/jpurnell/quality-gate-swift/commits/HEAD")
    }

    @Test("The tag prefix is applied to every ref, because a URL cannot normalise one away")
    func tagPrefixAppliesToEveryRef() throws {
        let root = try TemporaryDocProject.make(changelog: Self.changelog)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ChangelogLinksGenerator().generate(
            projectRoot: root, currentBody: "",
            configuration: Self.configuration(tagPrefix: "v"))

        #expect(body.lines[0].hasSuffix("/compare/v2.0.2...HEAD"))
        #expect(body.lines[1] == "[2.0.2]: https://github.com/jpurnell/quality-gate-swift/compare/v2026.07.12...v2.0.2")
        // The bracketed label is the heading's, never the tag's: the label is what the
        // document's `[2.0.2]` reference resolves against, and prefixing it breaks the link
        // it was supposed to define.
        #expect(!body.contains("[v2.0.2]:"))
    }

    @Test("A trailing slash on the configured URL does not become a double slash")
    func trailingSlashIsTrimmed() throws {
        let root = try TemporaryDocProject.make(changelog: Self.changelog)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ChangelogLinksGenerator().generate(
            projectRoot: root, currentBody: "",
            configuration: Self.configuration(
                repositoryURL: "https://github.com/jpurnell/quality-gate-swift/"))

        #expect(!body.contains("//compare"))
        #expect(body.lines[0].contains("quality-gate-swift/compare/"))
    }

    @Test("No repository URL is ungeneratable — a guessed host is a link that lies")
    func absentRepositoryURLThrows() throws {
        let root = try TemporaryDocProject.make(changelog: Self.changelog)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try ChangelogLinksGenerator().generate(
                projectRoot: root, currentBody: "",
                configuration: Self.configuration(repositoryURL: nil))
        }
    }

    @Test("A blank repository URL is absent, not a base of empty string")
    func blankRepositoryURLThrows() throws {
        let root = try TemporaryDocProject.make(changelog: Self.changelog)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try ChangelogLinksGenerator().generate(
                projectRoot: root, currentBody: "",
                configuration: Self.configuration(repositoryURL: "   "))
        }
    }

    @Test("An absent CHANGELOG is ungeneratable — reported, never silently skipped")
    func absentChangelogThrows() throws {
        let root = try TemporaryDocProject.make(readme: "# Readme\n")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try ChangelogLinksGenerator().generate(
                projectRoot: root, currentBody: "", configuration: Self.configuration())
        }
    }

    @Test("A CHANGELOG with no version heading is ungeneratable, not an empty region")
    func noVersionHeadingsThrows() throws {
        let root = try TemporaryDocProject.make(changelog: """
        # Changelog

        Nothing has been released and nobody wrote a heading.
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: RegionGeneratorError.self) {
            try ChangelogLinksGenerator().generate(
                projectRoot: root, currentBody: "", configuration: Self.configuration())
        }
    }

    @Test("The current body is ignored: every line here is derived, so drift is drift")
    func currentBodyIsIgnored() throws {
        let root = try TemporaryDocProject.make(changelog: Self.changelog)
        defer { try? FileManager.default.removeItem(at: root) }

        let generator = ChangelogLinksGenerator()
        let fromEmpty = try generator.generate(
            projectRoot: root, currentBody: "", configuration: Self.configuration())
        let fromStale = try generator.generate(
            projectRoot: root, currentBody: "[9.9.9]: https://example.com/nonsense",
            configuration: Self.configuration())

        #expect(fromEmpty == fromStale)
    }

    @Test("Regenerating its own output changes nothing, or the file is permanently dirty")
    func idempotent() throws {
        let root = try TemporaryDocProject.make(changelog: Self.changelog)
        defer { try? FileManager.default.removeItem(at: root) }

        let generator = ChangelogLinksGenerator()
        let once = try generator.generate(
            projectRoot: root, currentBody: "", configuration: Self.configuration())
        let twice = try generator.generate(
            projectRoot: root, currentBody: once, configuration: Self.configuration())

        #expect(once == twice)
    }

    @Test("Delimiters inside the CHANGELOG are not headings, so the region cannot define itself")
    func ownRegionIsNotAHeading() throws {
        let root = try TemporaryDocProject.make(changelog: """
        # Changelog

        ## [1.0.0] — 2026-01-01

        <!-- generated:changelog-links -->
        [1.0.0]: https://github.com/jpurnell/quality-gate-swift/releases/tag/1.0.0
        <!-- /generated:changelog-links -->
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let body = try ChangelogLinksGenerator().generate(
            projectRoot: root, currentBody: "", configuration: Self.configuration())

        #expect(body == "[1.0.0]: https://github.com/jpurnell/quality-gate-swift/releases/tag/1.0.0")
    }

    @Test("The registry can be asked for this generator by the id in the delimiters")
    func registered() {
        #expect(RegionGeneratorRegistry.ids.contains("changelog-links"))
        #expect(RegionGeneratorRegistry.generator(for: "changelog-links")?.id == "changelog-links")
    }
}
