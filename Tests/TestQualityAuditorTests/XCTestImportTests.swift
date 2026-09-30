import Foundation
import Testing
import TestQualityAuditor
import QualityGateCore

/// `xctest-import` — a test file reaching for the framework this project left behind.
///
/// The convention is Swift Testing, and it holds at 3602 `@Test` and 6338 `#expect` against
/// six files that still import XCTest. It held by habit rather than by enforcement: nothing
/// checked, so the exception survived in — of all places — this auditor's own test suite.
///
/// The rule exists so the convention stops depending on whoever reviews the diff.
@Suite("xctest-import")
struct XCTestImportTests {

    private let auditor = TestQualityAuditor()
    private let ruleId = "xctest-import"

    private func diagnostics(_ source: String, fileName: String = "SomeTests.swift") async throws -> [Diagnostic] {
        let result = try await auditor.auditSource(
            source, fileName: fileName, configuration: Configuration())
        return result.diagnostics.filter { $0.ruleId == ruleId }
    }

    @Test("A test file importing XCTest is an error")
    func flagsXCTestImport() async throws {
        let found = try await diagnostics("""
        import XCTest
        import TestQualityAuditor

        final class CoalescedAssertionTests: XCTestCase {
            func testSomething() {
                XCTAssertEqual(1, 1)
            }
        }
        """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == 1)
    }

    @Test("A Swift Testing file is not flagged")
    func swiftTestingIsClean() async throws {
        let found = try await diagnostics("""
        import Testing

        @Suite("Thing")
        struct ThingTests {
            @Test("it works")
            func itWorks() {
                #expect(1 == 1)
            }
        }
        """)
        #expect(found.isEmpty)
    }

    @Test("The fix names the replacement, not just the offence")
    func suggestedFixIsActionable() async throws {
        // A rule that says "do not use XCTest" and stops is a rule someone has to translate.
        // The whole migration is mechanical, so the message can carry the mechanics.
        let found = try await diagnostics("import XCTest\nfinal class T: XCTestCase {}")
        let fix = try #require(found.first?.suggestedFix)
        #expect(fix.contains("Testing"))
    }

    @Test("Importing XCTest alongside Testing is still flagged")
    func mixedImportsStillFlagged() async throws {
        // The likely shape of a half-finished migration, and the one most worth catching:
        // the file looks converted until you read the first line.
        let found = try await diagnostics("""
        import XCTest
        import Testing

        @Suite("Half")
        struct HalfTests {
            @Test("t") func t() { #expect(true) }
        }
        """)
        #expect(found.count == 1)
    }

    @Test("A non-test file importing XCTest is left alone")
    func nonTestFileIgnored() async throws {
        // The auditor's subject is test code. A helper target that legitimately links XCTest
        // is not this rule's business, and flagging it would teach people to disable the rule.
        let found = try await diagnostics(
            "import XCTest\npublic struct Helper {}",
            fileName: "Sources/Helper/Helper.swift")
        #expect(found.isEmpty)
    }
}
