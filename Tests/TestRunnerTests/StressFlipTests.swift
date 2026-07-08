import Foundation
import Testing
@testable import TestRunner
@testable import QualityGateCore

@Suite("TestRunner: intra-batch stress flips")
struct StressFlipTests {

    private func roster(_ outcomes: [(String, Bool)]) -> [TestOutcome] {
        outcomes.map { TestOutcome(suite: "S", test: $0.0, passed: $0.1) }
    }

    @Test("Unanimous outcomes across runs produce no stress flips")
    func unanimousNoFlips() {
        let rosters = [roster([("a", true)]), roster([("a", true)]), roster([("a", true)])]
        #expect(TestRunner.stressFlips(rosters: rosters).isEmpty)
    }

    @Test("Unanimous failures are not a flip (just a failing test)")
    func unanimousFailuresNotFlips() {
        let rosters = [roster([("a", false)]), roster([("a", false)])]
        #expect(TestRunner.stressFlips(rosters: rosters).isEmpty)
    }

    @Test("A test that both passes and fails across runs is a stress flip")
    func mixedIsFlip() {
        let rosters = [
            roster([("a", true)]),
            roster([("a", false)]),
            roster([("a", true)])
        ]
        let flips = TestRunner.stressFlips(rosters: rosters)
        #expect(flips.count == 1)
        #expect(flips.first?.test == "a")
        #expect(flips.first?.passes == 2)
        #expect(flips.first?.failures == 1)
    }

    @Test("Only the flipping test is reported among stable ones")
    func isolatesFlipping() {
        let rosters = [
            roster([("stable", true), ("racy", true)]),
            roster([("stable", true), ("racy", false)])
        ]
        let flips = TestRunner.stressFlips(rosters: rosters)
        #expect(flips.map(\.test) == ["racy"])
    }

    @Test("Fewer than two rosters cannot flip")
    func singleRosterNoFlip() {
        #expect(TestRunner.stressFlips(rosters: [roster([("a", true)])]).isEmpty)
        #expect(TestRunner.stressFlips(rosters: []).isEmpty)
    }

    // MARK: - Diagnostics

    @Test("A stress flip becomes a warning by default with the definitive-race framing")
    func stressDiagnosticWarning() {
        let flip = TestRunner.StressFlip(suite: "S", test: "racy", passes: 2, failures: 1)
        let diags = TestRunner.stressDiagnostics(for: [flip], runs: 3, strict: false)
        #expect(diags.count == 1)
        #expect(diags.first?.severity == .warning)
        #expect(diags.first?.ruleId == "test.stress-flip")
        #expect(diags.first?.message.contains("racy") == true)
        #expect(diags.first?.message.contains("3") == true)   // run count surfaced
    }

    @Test("Strict mode raises a stress flip to an error")
    func stressDiagnosticStrict() {
        let flip = TestRunner.StressFlip(suite: "S", test: "racy", passes: 1, failures: 1)
        #expect(TestRunner.stressDiagnostics(for: [flip], runs: 2, strict: true).first?.severity == .error)
    }
}
