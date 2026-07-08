import Foundation
import Testing
@testable import QualityGateCore

@Suite("FlipDetector: scheduler-dependent outcome flips")
struct FlipDetectorTests {

    private func record(
        fingerprint: String = "fp-1",
        commit: String = "c1",
        loadProxy: Int = 1,
        _ outcomes: [(String, String, Bool)]
    ) -> TestRunRecord {
        TestRunRecord(
            packageFingerprint: fingerprint,
            commit: commit,
            loadProxy: loadProxy,
            outcomes: outcomes.map { TestOutcome(suite: $0.0, test: $0.1, passed: $0.2) }
        )
    }

    @Test("No previous record → no flips")
    func noPreviousRecord() {
        let current = record([("S", "t", true)])
        #expect(FlipDetector.flips(previous: nil, current: current).isEmpty)
    }

    @Test("Pass → fail on an unchanged package is a flip")
    func passToFailFlips() {
        let previous = record(commit: "c1", [("S", "t", true)])
        let current = record(commit: "c2", [("S", "t", false)])
        let flips = FlipDetector.flips(previous: previous, current: current)
        #expect(flips.count == 1)
        #expect(flips.first?.test == "t")
        #expect(flips.first?.previouslyPassed == true)
        #expect(flips.first?.nowPassed == false)
        #expect(flips.first?.previousCommit == "c1")
        #expect(flips.first?.currentCommit == "c2")
    }

    @Test("Fail → pass on an unchanged package is also a flip")
    func failToPassFlips() {
        let previous = record([("S", "t", false)])
        let current = record([("S", "t", true)])
        #expect(FlipDetector.flips(previous: previous, current: current).count == 1)
    }

    @Test("A changed package fingerprint suppresses flips (expected change)")
    func changedPackageSuppressesFlips() {
        let previous = record(fingerprint: "fp-1", [("S", "t", true)])
        let current = record(fingerprint: "fp-2", [("S", "t", false)])
        #expect(FlipDetector.flips(previous: previous, current: current).isEmpty)
    }

    @Test("Stable outcomes produce no flips")
    func stableNoFlips() {
        let previous = record([("S", "a", true), ("S", "b", false)])
        let current = record([("S", "a", true), ("S", "b", false)])
        #expect(FlipDetector.flips(previous: previous, current: current).isEmpty)
    }

    @Test("A test present only in the current run is not a flip")
    func newTestNotAFlip() {
        let previous = record([("S", "a", true)])
        let current = record([("S", "a", true), ("S", "b", false)])
        #expect(FlipDetector.flips(previous: previous, current: current).isEmpty)
    }

    @Test("Same test name in different suites is tracked independently")
    func suiteScopedKeys() {
        let previous = record([("S1", "t", true), ("S2", "t", true)])
        let current = record([("S1", "t", false), ("S2", "t", true)])
        let flips = FlipDetector.flips(previous: previous, current: current)
        #expect(flips.count == 1)
        #expect(flips.first?.suite == "S1")
    }

    @Test("TestRunRecord round-trips through Codable")
    func recordCodableRoundTrip() throws {
        let original = record(commit: "abc", loadProxy: 8, [("S", "t", true)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TestRunRecord.self, from: data)
        #expect(decoded == original)
    }
}
