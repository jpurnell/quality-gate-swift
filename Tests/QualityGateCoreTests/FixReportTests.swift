import Foundation
import Testing
import QualityGateCore

/// What `--fix` and `--fix --dry-run` print for one checker.
@Suite("FixReport")
struct FixReportTests {

    private let given = [
        Diagnostic(
            severity: .error, message: "Test file imports XCTest.", filePath: "Tests/A/ATests.swift",
            lineNumber: 1, ruleId: "xctest-import"),
        Diagnostic(
            severity: .error, message: "Test file imports XCTest.", filePath: "Tests/A/BTests.swift",
            lineNumber: 1, ruleId: "xctest-import"),
        Diagnostic(
            severity: .warning, message: "weak", filePath: "Tests/A/CTests.swift",
            lineNumber: 9, ruleId: "weak-assertion"),
    ]

    private var result: FixResult {
        FixResult(
            modifications: [
                FileModification(
                    filePath: "Tests/A/ATests.swift", description: "Converted to Swift Testing (4 tests)",
                    linesChanged: 23),
            ],
            unfixed: [
                given[2],
                Diagnostic(
                    severity: .error, message: "expectation: Swift Testing waits with `await`.",
                    filePath: "Tests/A/BTests.swift", lineNumber: 12, ruleId: "xctest-import"),
                Diagnostic(
                    severity: .error, message: "BTests.swift could not be written: disk full",
                    filePath: "Tests/A/BTests.swift", lineNumber: nil, ruleId: "xctest-import"),
            ])
    }

    @Test("An applied fix lists each changed file, then each file left alone with its reasons under it")
    func appliedListsEveryDeclinedFileWithItsReasons() {
        #expect(FixReport.applied(result, given: given) == [
            "  ✓ Tests/A/ATests.swift — Converted to Swift Testing (4 tests), 23 lines",
            "  ✗ Tests/A/BTests.swift — not changed:",
            "      line 12: expectation: Swift Testing waits with `await`.",
            "      BTests.swift could not be written: disk full",
            "  ℹ  1 other finding is not auto-fixable; see the report below",
        ])
    }

    @Test("A preview states the same facts in the conditional")
    func previewSaysWould() {
        #expect(FixReport.preview(result, given: given) == [
            "  would change Tests/A/ATests.swift — Converted to Swift Testing (4 tests), 23 lines",
            "  would not change Tests/A/BTests.swift:",
            "      line 12: expectation: Swift Testing waits with `await`.",
            "      BTests.swift could not be written: disk full",
            "  ℹ  1 other finding is not auto-fixable; see the report below",
        ])
    }

    @Test("A finding the fixer was given and handed back is counted, not listed as a reason")
    func passedThroughFindingsAreOnlyCounted() {
        let untouched = FixResult(modifications: [], unfixed: [given[2], given[0]])
        #expect(FixReport.applied(untouched, given: given) == [
            "  ℹ  2 other findings are not auto-fixable; see the report below",
        ])
    }

    @Test("Nothing changed and nothing declined prints nothing")
    func emptyResultPrintsNothing() {
        #expect(FixReport.applied(.noChanges, given: given) == [])
        #expect(FixReport.preview(.noChanges, given: []) == [])
    }

    @Test("A backup path is shown, and one changed line is singular")
    func backupAndSingular() {
        let backedUp = FixResult(
            modifications: [
                FileModification(
                    filePath: "README.md", description: "Updated test count", linesChanged: 1,
                    backupPath: "README.md.backup"),
            ],
            unfixed: [])
        #expect(FixReport.applied(backedUp, given: []) == [
            "  ✓ README.md — Updated test count, 1 line (backup: README.md.backup)",
        ])
    }

    @Test("A checker with no preview of its own returns nil, so the CLI falls back to the rule's advice")
    func defaultPreviewIsNil() async throws {
        struct Plain: FixableChecker {
            let id = "plain"
            let name = "Plain"
            let summary = "A checker that cannot preview its fix"
            let category = CheckerCategory.codeHygiene
            let kind = CheckerKind.code
            let effect = CheckerEffect.readOnly
            let executesProjectCode = false
            let fixDescription = "Does nothing."

            func check(configuration: Configuration) async throws -> CheckResult {
                CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
            }

            func fix(diagnostics: [Diagnostic], configuration: Configuration) async throws -> FixResult {
                .noChanges
            }
        }
        #expect(try await Plain().previewFix(diagnostics: [], configuration: Configuration()) == nil)
    }
}
