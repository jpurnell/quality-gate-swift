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
