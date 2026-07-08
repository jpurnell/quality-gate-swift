import Foundation
import Testing
@testable import TestRunner
@testable import QualityGateCore

@Suite("TestRunner: roster parsing (pass/fail per test)")
struct TestRosterParsingTests {

    // MARK: - Swift Testing

    @Test("Parses a passed Swift Testing line")
    func parsesSwiftTestingPass() {
        let output = #"􁁛  Test "does the thing" passed after 0.001 seconds."#
        let roster = TestRunner.parseTestRoster(output)
        #expect(roster.count == 1)
        #expect(roster.first?.test == "does the thing")
        #expect(roster.first?.passed == true)
    }

    @Test("Parses a failed Swift Testing line (with issue count)")
    func parsesSwiftTestingFail() {
        let output = #"􀢄  Test "handles the edge case" failed after 0.008 seconds with 1 issue."#
        let roster = TestRunner.parseTestRoster(output)
        #expect(roster.count == 1)
        #expect(roster.first?.test == "handles the edge case")
        #expect(roster.first?.passed == false)
    }

    @Test("Ignores Suite lines and started lines")
    func ignoresSuiteAndStarted() {
        let output = """
        􀟈  Suite "My Suite" started.
        􀟈  Test "a" started.
        􁁛  Test "a" passed after 0.001 seconds.
        􁁛  Suite "My Suite" passed after 0.010 seconds.
        """
        let roster = TestRunner.parseTestRoster(output)
        #expect(roster.count == 1)
        #expect(roster.first?.test == "a")
    }

    @Test("Parses a mixed roster of passes and failures")
    func parsesMixedRoster() {
        let output = """
        􁁛  Test "a" passed after 0.001 seconds.
        􀢄  Test "b" failed after 0.002 seconds with 1 issue.
        􁁛  Test "c" passed after 0.003 seconds.
        """
        let roster = TestRunner.parseTestRoster(output)
        #expect(roster.count == 3)
        #expect(roster.filter { $0.passed }.map(\.test).sorted() == ["a", "c"])
        #expect(roster.filter { !$0.passed }.map(\.test) == ["b"])
    }

    // MARK: - XCTest

    @Test("Parses XCTest pass/fail with suite from the bracketed target")
    func parsesXCTest() {
        let output = """
        Test Case '-[MyTests.MathTests testAdds]' passed (0.001 seconds).
        Test Case '-[MyTests.MathTests testDivides]' failed (0.002 seconds).
        """
        let roster = TestRunner.parseTestRoster(output)
        #expect(roster.count == 2)
        let adds = roster.first { $0.test == "testAdds" }
        #expect(adds?.passed == true)
        #expect(adds?.suite == "MyTests.MathTests")
        #expect(roster.first { $0.test == "testDivides" }?.passed == false)
    }

    // MARK: - Robustness

    @Test("Empty output yields an empty roster")
    func emptyOutput() {
        #expect(TestRunner.parseTestRoster("").isEmpty)
    }

    @Test("Does not confuse 'recorded an issue' lines for outcomes")
    func ignoresRecordedIssueLines() {
        let output = #"􀢄  Test "b" recorded an issue at File.swift:10:5: Expectation failed"#
        // No "passed"/"failed after" outcome line here — only the issue detail.
        #expect(TestRunner.parseTestRoster(output).isEmpty)
    }
}
