import Foundation
import Testing
@testable import TestRunner
@testable import QualityGateCore

@Suite("TestRunner: flip → diagnostic mapping")
struct FlipDiagnosticsTests {

    private let flip = TestOutcomeFlip(
        suite: "MathTests",
        test: "testDivides",
        previouslyPassed: true,
        nowPassed: false,
        previousCommit: "aaa111",
        currentCommit: "bbb222"
    )

    @Test("No flips → no diagnostics")
    func noFlipsNoDiagnostics() {
        #expect(TestRunner.flipDiagnostics(for: [], strict: false).isEmpty)
    }

    @Test("A flip becomes a warning by default with the scheduler-dependent framing")
    func flipIsWarningByDefault() throws {
        let diags = TestRunner.flipDiagnostics(for: [flip], strict: false)
        #expect(diags.count == 1)
        let diag = try #require(diags.first)
        #expect(diag.severity == .warning)
        #expect(diag.ruleId == "test.outcome-flip")
        #expect(diag.message.contains("testDivides"))
        #expect(diag.message.contains("scheduler-dependent"))
        // Both commits surface so the window can be found.
        #expect(diag.message.contains("aaa111"))
        #expect(diag.message.contains("bbb222"))
    }

    @Test("Strict mode raises the flip to an error")
    func strictIsError() {
        let diags = TestRunner.flipDiagnostics(for: [flip], strict: true)
        #expect(diags.first?.severity == .error)
    }
}
