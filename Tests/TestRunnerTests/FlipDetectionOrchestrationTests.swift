import Foundation
import Testing
@testable import TestRunner
@testable import QualityGateCore

@Suite("TestRunner: flipDetection orchestration")
struct FlipDetectionOrchestrationTests {

    @Test("Empty roster persists no record and emits no diagnostics (build failure guard)")
    func emptyRosterGuard() {
        let previous = TestRunRecord(
            packageFingerprint: "fp", commit: "c1", loadProxy: 1,
            outcomes: [TestOutcome(suite: "S", test: "t", passed: true)]
        )
        let (diags, record) = TestRunner.flipDetection(
            roster: [], previous: previous,
            packageFingerprint: "fp", commit: "c2", loadProxy: 1, strict: false
        )
        #expect(diags.isEmpty)
        #expect(record == nil)   // must NOT overwrite the last good roster
    }

    @Test("First run (no previous) persists a record but flags nothing")
    func firstRunPersistsNoFlips() {
        let roster = [TestOutcome(suite: "S", test: "t", passed: true)]
        let (diags, record) = TestRunner.flipDetection(
            roster: roster, previous: nil,
            packageFingerprint: "fp", commit: "c1", loadProxy: 2, strict: false
        )
        #expect(diags.isEmpty)
        #expect(record?.outcomes == roster)
        #expect(record?.loadProxy == 2)
    }

    @Test("A flip on an unchanged package emits a diagnostic and a fresh record")
    func flipEmitsDiagnosticAndRecord() {
        let previous = TestRunRecord(
            packageFingerprint: "fp", commit: "c1", loadProxy: 1,
            outcomes: [TestOutcome(suite: "S", test: "t", passed: true)]
        )
        let roster = [TestOutcome(suite: "S", test: "t", passed: false)]
        let (diags, record) = TestRunner.flipDetection(
            roster: roster, previous: previous,
            packageFingerprint: "fp", commit: "c2", loadProxy: 1, strict: false
        )
        #expect(diags.count == 1)
        #expect(diags.first?.ruleId == "test.outcome-flip")
        #expect(record?.commit == "c2")
    }
}
