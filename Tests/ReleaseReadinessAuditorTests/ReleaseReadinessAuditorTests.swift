import Foundation
import Testing
@testable import ReleaseReadinessAuditor
@testable import QualityGateCore

// MARK: - Identity

@Suite("ReleaseReadinessAuditor: Identity")
struct ReleaseReadinessAuditorIdentityTests {

    @Test("Has correct id")
    func id() {
        let auditor = ReleaseReadinessAuditor()
        #expect(auditor.id == "release-readiness")
    }

    @Test("Has correct name")
    func name() {
        let auditor = ReleaseReadinessAuditor()
        #expect(auditor.name == "Release Readiness Auditor")
    }
}

// MARK: - Changelog Checks

@Suite("ReleaseReadinessAuditor: checkChangelog")
struct ChangelogTests {

    @Test("Returns no diagnostics when version is found in heading")
    func versionPresent() {
        let content = """
        # Changelog

        ## 1.2.0

        - Added new feature
        """
        let diagnostics = ReleaseReadinessAuditor.checkChangelog(
            content: content,
            version: "1.2.0"
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Returns no diagnostics when version is found in bracketed heading")
    func versionPresentBracketed() {
        let content = """
        # Changelog

        ## [1.2.0] - 2026-04-29

        - Added new feature
        """
        let diagnostics = ReleaseReadinessAuditor.checkChangelog(
            content: content,
            version: "1.2.0"
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Returns warning when version is missing from changelog")
    func versionMissing() {
        let content = """
        # Changelog

        ## 1.1.0

        - Previous release
        """
        let diagnostics = ReleaseReadinessAuditor.checkChangelog(
            content: content,
            version: "1.2.0"
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.ruleId == "release-changelog")
    }

    @Test("Returns warning when changelog is empty")
    func emptyChangelog() {
        let diagnostics = ReleaseReadinessAuditor.checkChangelog(
            content: "",
            version: "1.0.0"
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.ruleId == "release-changelog")
    }

    @Test("Returns no diagnostics when version is nil (could not detect)")
    func nilVersion() {
        let content = """
        # Changelog

        ## 1.0.0

        - Initial release
        """
        let diagnostics = ReleaseReadinessAuditor.checkChangelog(
            content: content,
            version: nil
        )
        #expect(diagnostics.isEmpty)
    }
}

// MARK: - README Checks

@Suite("ReleaseReadinessAuditor: checkReadme")
struct ReadmeTests {

    @Test("Returns no diagnostics for clean README")
    func cleanReadme() {
        let content = """
        # My Project

        A well-documented library for doing things.

        ## Installation

        Add the package to your dependencies.
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"],
            filePath: "README.md"
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Flags TODO in README")
    func flagsTodo() {
        let content = """
        # My Project

        TODO: Write better docs
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"],
            filePath: "README.md"
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.ruleId == "release-todo-readme")
        #expect(diagnostics.first?.lineNumber == 3)
    }

    @Test("Flags FIXME in README (case-insensitive)")
    func flagsFixmeCaseInsensitive() {
        let content = """
        # My Project

        fixme: this section needs work
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"],
            filePath: "README.md"
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.ruleId == "release-todo-readme")
    }

    @Test("Flags HACK marker")
    func flagsHack() {
        let content = """
        # My Project

        This is a HACK workaround.
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"],
            filePath: "README.md"
        )
        #expect(diagnostics.count == 1)
    }

    @Test("Flags XXX marker")
    func flagsXxx() {
        let content = """
        # My Project

        XXX: This needs attention
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"],
            filePath: "README.md"
        )
        #expect(diagnostics.count == 1)
    }

    @Test("Flags PLACEHOLDER marker")
    func flagsPlaceholder() {
        let content = """
        # My Project

        PLACEHOLDER text goes here
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"],
            filePath: "README.md"
        )
        #expect(diagnostics.count == 1)
    }

    @Test("Flags multiple markers on different lines")
    func flagsMultiple() {
        let content = """
        # My Project

        TODO: Write docs
        FIXME: Fix the example
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"],
            filePath: "README.md"
        )
        #expect(diagnostics.count == 2)
    }

    @Test("Does not flag markers embedded in larger words")
    func noFalsePositivesForSubstrings() {
        let content = """
        # My Project

        Zero regex shortcuts — every rule walks the AST.
        CHANGELOG entries, README placeholders, bare to-do markers.
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER"],
            filePath: "README.md"
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Checks additional custom markers")
    func additionalMarkers() {
        let content = """
        # My Project

        NEEDSWORK: Improve this section
        """
        let diagnostics = ReleaseReadinessAuditor.checkReadme(
            content: content,
            markers: ["TODO", "FIXME", "HACK", "XXX", "PLACEHOLDER", "NEEDSWORK"],
            filePath: "README.md"
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.ruleId == "release-todo-readme")
    }
}

// MARK: - Source TODO Checks

@Suite("ReleaseReadinessAuditor: checkSourceTodos")
struct SourceTodoTests {

    @Test("Flags bare TODO when requireIssueReference is true")
    func flagsBareTodo() {
        let content = """
        func doWork() {
            // TODO: implement this
        }
        """
        let diagnostics = ReleaseReadinessAuditor.checkSourceTodos(
            content: content,
            filePath: "Sources/MyModule/File.swift",
            requireIssueReference: true
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .warning)
        #expect(diagnostics.first?.ruleId == "release-todo-sources")
        #expect(diagnostics.first?.lineNumber == 2)
    }

    @Test("Flags bare FIXME when requireIssueReference is true")
    func flagsBareFixme() {
        let content = """
        func doWork() {
            // FIXME: broken logic
        }
        """
        let diagnostics = ReleaseReadinessAuditor.checkSourceTodos(
            content: content,
            filePath: "Sources/MyModule/File.swift",
            requireIssueReference: true
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.ruleId == "release-todo-sources")
    }

    @Test("Does not flag TODO(#123) with issue reference")
    func allowsTodoWithIssueRef() {
        let content = """
        func doWork() {
            // TODO(#123): implement this
        }
        """
        let diagnostics = ReleaseReadinessAuditor.checkSourceTodos(
            content: content,
            filePath: "Sources/MyModule/File.swift",
            requireIssueReference: true
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Does not flag FIXME(JIRA-456) with issue reference")
    func allowsFixmeWithJiraRef() {
        let content = """
        func doWork() {
            // FIXME(JIRA-456): fix this
        }
        """
        let diagnostics = ReleaseReadinessAuditor.checkSourceTodos(
            content: content,
            filePath: "Sources/MyModule/File.swift",
            requireIssueReference: true
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Returns no diagnostics when no TODOs or FIXMEs present")
    func noTodos() {
        let content = """
        func doWork() {
            let result = compute()
            return result
        }
        """
        let diagnostics = ReleaseReadinessAuditor.checkSourceTodos(
            content: content,
            filePath: "Sources/MyModule/File.swift",
            requireIssueReference: true
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Returns no diagnostics when requireIssueReference is false")
    func skipsWhenNotRequired() {
        let content = """
        func doWork() {
            // TODO: implement this
            // FIXME: broken
        }
        """
        let diagnostics = ReleaseReadinessAuditor.checkSourceTodos(
            content: content,
            filePath: "Sources/MyModule/File.swift",
            requireIssueReference: false
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Flags multiple bare TODOs")
    func flagsMultiple() {
        let content = """
        // TODO: first thing
        func a() {}
        // FIXME: second thing
        func b() {}
        """
        let diagnostics = ReleaseReadinessAuditor.checkSourceTodos(
            content: content,
            filePath: "Sources/MyModule/File.swift",
            requireIssueReference: true
        )
        #expect(diagnostics.count == 2)
    }

    @Test("Case-insensitive TODO detection")
    func caseInsensitive() {
        let content = """
        // todo: lowercase
        // Todo: mixed case
        """
        let diagnostics = ReleaseReadinessAuditor.checkSourceTodos(
            content: content,
            filePath: "Sources/MyModule/File.swift",
            requireIssueReference: true
        )
        #expect(diagnostics.count == 2)
    }
}

// MARK: - Version Normalization

@Suite("ReleaseReadinessAuditor: normalizeVersion")
struct NormalizeVersionTests {

    @Test("Strips leading lowercase v")
    func stripsLowercaseV() {
        #expect(ReleaseReadinessAuditor.normalizeVersion("v1.2.0") == "1.2.0")
    }

    @Test("Strips leading uppercase V")
    func stripsUppercaseV() {
        #expect(ReleaseReadinessAuditor.normalizeVersion("V2.0.1") == "2.0.1")
    }

    @Test("Leaves bare semver untouched")
    func leavesBareUntouched() {
        #expect(ReleaseReadinessAuditor.normalizeVersion("1.2.0") == "1.2.0")
    }

    @Test("Trims surrounding whitespace")
    func trimsWhitespace() {
        #expect(ReleaseReadinessAuditor.normalizeVersion("  v1.0.0  ") == "1.0.0")
    }

    @Test("Strips a monorepo Project@v prefix")
    func stripsProjectPrefixWithV() {
        #expect(ReleaseReadinessAuditor.normalizeVersion("IconquerApp@v0.1.0") == "0.1.0")
    }

    @Test("Strips a monorepo Project@ prefix without a v")
    func stripsProjectPrefixWithoutV() {
        #expect(ReleaseReadinessAuditor.normalizeVersion("IconquerMCP@0.2.0") == "0.2.0")
    }

    @Test("Strips only up to the last @ when a scope contains one")
    func stripsToLastAt() {
        #expect(ReleaseReadinessAuditor.normalizeVersion("scope@pkg@v3.4.5") == "3.4.5")
    }

    @Test("Trims whitespace around a prefixed tag")
    func trimsPrefixedWhitespace() {
        #expect(ReleaseReadinessAuditor.normalizeVersion("  IconquerGameKit@v0.1.0  ") == "0.1.0")
    }
}

// MARK: - Latest Changelog Version Parsing

@Suite("ReleaseReadinessAuditor: parseLatestChangelogVersion")
struct ParseLatestChangelogVersionTests {

    @Test("Extracts topmost released version from plain heading")
    func topmostPlain() {
        let content = """
        # Changelog

        ## 2.0.1

        - latest

        ## 2.0.0

        - older
        """
        #expect(ReleaseReadinessAuditor.parseLatestChangelogVersion(content: content) == "2.0.1")
    }

    @Test("Extracts version from bracketed dated heading")
    func bracketedDated() {
        let content = """
        # Changelog

        ## [1.4.0] - 2026-06-07

        - stuff
        """
        #expect(ReleaseReadinessAuditor.parseLatestChangelogVersion(content: content) == "1.4.0")
    }

    @Test("Skips an Unreleased heading and returns the next released version")
    func skipsUnreleased() {
        let content = """
        # Changelog

        ## [Unreleased]

        - work in progress

        ## 1.2.0

        - released
        """
        #expect(ReleaseReadinessAuditor.parseLatestChangelogVersion(content: content) == "1.2.0")
    }

    @Test("Returns nil when only an Unreleased section exists")
    func onlyUnreleased() {
        let content = """
        # Changelog

        ## [Unreleased]

        - nothing shipped yet
        """
        #expect(ReleaseReadinessAuditor.parseLatestChangelogVersion(content: content) == nil)
    }

    @Test("Strips a v prefix on the changelog heading")
    func stripsVPrefix() {
        let content = """
        # Changelog

        ## v3.1.0

        - stuff
        """
        #expect(ReleaseReadinessAuditor.parseLatestChangelogVersion(content: content) == "3.1.0")
    }
}


// MARK: - README Dependency Version Parsing

@Suite("ReleaseReadinessAuditor: parseReadmeDependencyVersions")
struct ParseReadmeDependencyVersionsTests {

    @Test("Extracts a from: version")
    func fromVersion() {
        let content = #"""
        Add to your Package.swift:

        .package(url: "https://example.com/pkg", from: "2.0.0")
        """#
        let versions = ReleaseReadinessAuditor.parseReadmeDependencyVersions(content: content)
        #expect(versions.contains("2.0.0"))
    }

    @Test("Extracts an exact version")
    func exactVersion() {
        let content = #"""
        .package(url: "https://example.com/pkg", .exact("1.3.1"))
        """#
        let versions = ReleaseReadinessAuditor.parseReadmeDependencyVersions(content: content)
        #expect(versions.contains("1.3.1"))
    }

    @Test("Extracts an upToNextMajor from: version")
    func upToNextMajorVersion() {
        let content = #"""
        .package(url: "u", .upToNextMajor(from: "0.4.0"))
        """#
        let versions = ReleaseReadinessAuditor.parseReadmeDependencyVersions(content: content)
        #expect(versions.contains("0.4.0"))
    }

    @Test("Returns empty for a README with no dependency versions")
    func none() {
        let content = "# My Project\n\nJust prose, no package versions here."
        let versions = ReleaseReadinessAuditor.parseReadmeDependencyVersions(content: content)
        #expect(versions.isEmpty)
    }
}

// MARK: - Dependency Resolvability

@Suite("ReleaseReadinessAuditor: checkDependencyVersionsResolvable")
struct DependencyResolvableTests {

    @Test("No diagnostics when every advertised version is tagged")
    func allResolvable() {
        let diagnostics = ReleaseReadinessAuditor.checkDependencyVersionsResolvable(
            readmeVersions: ["1.0.0", "1.1.0"],
            tags: ["v1.0.0", "v1.1.0", "v1.2.0"]
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Errors for an advertised version with no matching tag")
    func unresolvable() {
        let diagnostics = ReleaseReadinessAuditor.checkDependencyVersionsResolvable(
            readmeVersions: ["2.0.0"],
            tags: ["v1.0.0"]
        )
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.severity == .error)
        #expect(diagnostics.first?.ruleId == "release-unresolvable-dependency")
    }

    @Test("Reports one diagnostic per unresolvable version")
    func multipleUnresolvable() {
        let diagnostics = ReleaseReadinessAuditor.checkDependencyVersionsResolvable(
            readmeVersions: ["2.0.0", "3.0.0"],
            tags: ["v1.0.0"]
        )
        #expect(diagnostics.count == 2)
        #expect(diagnostics.allSatisfy { $0.ruleId == "release-unresolvable-dependency" })
    }

    @Test("No diagnostics when README advertises nothing")
    func nothingAdvertised() {
        let diagnostics = ReleaseReadinessAuditor.checkDependencyVersionsResolvable(
            readmeVersions: [],
            tags: []
        )
        #expect(diagnostics.isEmpty)
    }
}
