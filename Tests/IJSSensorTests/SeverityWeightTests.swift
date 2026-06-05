import Testing
import Foundation
@testable import IJSSensor

@Suite("SeverityWeight")
struct SeverityWeightTests {

    // MARK: - weightedScore

    @Test("All checkers pass yields 1.0")
    func allPass() {
        let results: [(checkerID: String, passed: Bool)] = [
            ("safety", true),
            ("concurrency", true),
            ("doc-coverage", true),
        ]
        let score = SeverityWeight.weightedScore(checkerResults: results)
        #expect(score == 1.0)
    }

    @Test("All checkers fail yields 0.0")
    func allFail() {
        let results: [(checkerID: String, passed: Bool)] = [
            ("safety", false),
            ("concurrency", false),
            ("doc-coverage", false),
        ]
        let score = SeverityWeight.weightedScore(checkerResults: results)
        #expect(score == 0.0)
    }

    @Test("Empty checkers yields 1.0")
    func emptyCheckers() {
        let score = SeverityWeight.weightedScore(checkerResults: [])
        #expect(score == 1.0)
    }

    @Test("Single checker pass yields 1.0")
    func singlePass() {
        let results: [(checkerID: String, passed: Bool)] = [("safety", true)]
        let score = SeverityWeight.weightedScore(checkerResults: results)
        #expect(score == 1.0)
    }

    @Test("Single checker fail yields 0.0")
    func singleFail() {
        let results: [(checkerID: String, passed: Bool)] = [("safety", false)]
        let score = SeverityWeight.weightedScore(checkerResults: results)
        #expect(score == 0.0)
    }

    @Test("Mixed results: only doc-coverage fails out of safety, concurrency, doc-coverage")
    func mixedResults() {
        let results: [(checkerID: String, passed: Bool)] = [
            ("safety", true),
            ("concurrency", true),
            ("doc-coverage", false),
        ]
        let score = SeverityWeight.weightedScore(checkerResults: results)
        // totalWeight = 1.0 + 1.0 + 0.2 = 2.2
        // failWeight = 0.2
        // score = 1.0 - 0.2/2.2 ≈ 0.90909...
        let expected = 1.0 - 0.2 / 2.2
        #expect(abs(score - expected) < 1e-10)
    }

    @Test("Unknown checker uses defaultUnknownWeight")
    func unknownChecker() {
        let results: [(checkerID: String, passed: Bool)] = [
            ("safety", true),
            ("totally-unknown-checker", false),
        ]
        let score = SeverityWeight.weightedScore(checkerResults: results)
        // totalWeight = 1.0 + 0.3 = 1.3
        // failWeight = 0.3
        // score = 1.0 - 0.3/1.3
        let expected = 1.0 - 0.3 / 1.3
        #expect(abs(score - expected) < 1e-10)
    }

    // MARK: - defaultWeightTable

    @Test("Default weight table has at least 29 entries")
    func weightTableSize() {
        #expect(SeverityWeight.defaultWeightTable.count >= 29)
    }

    @Test("All weights are in range [0.0, 1.0]")
    func weightsInRange() {
        for (checkerID, weight) in SeverityWeight.defaultWeightTable {
            #expect(weight >= 0.0, "Weight for \(checkerID) is below 0.0")
            #expect(weight <= 1.0, "Weight for \(checkerID) is above 1.0")
        }
    }
}
