import Testing
import Foundation
import QualityGateTypes
@testable import IJSRefiner
import IJSSensor
import IJSAggregator

@Suite("PulseRefiner Weighted Scoring")
struct WeightedScoringTests {

    private let writer = TelemetryWriter()

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeMetadata(
        projectID: String = "test-project",
        timestamp: Date,
        passedCheckerIds: [String] = [],
        failedCheckerIds: [String] = []
    ) -> CheckResultMetadata {
        var results: [CheckResult] = []
        for checkerId in passedCheckerIds {
            results.append(CheckResult(
                checkerId: checkerId,
                status: .passed,
                diagnostics: [],
                overrides: [],
                duration: .zero
            ))
        }
        for checkerId in failedCheckerIds {
            results.append(CheckResult(
                checkerId: checkerId,
                status: .failed,
                diagnostics: [],
                overrides: [],
                duration: .zero
            ))
        }
        return CheckResultMetadata(
            projectID: projectID,
            timestamp: timestamp,
            environment: .local,
            decisionOwner: "test-owner",
            results: results,
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil
        )
    }

    @Test("All checkers pass produces score of 1.0")
    func allPass() async {
        let refiner = PulseRefiner(writer: writer)
        let metadata = [
            makeMetadata(
                timestamp: makeDate("2026-05-01T10:00:00"),
                passedCheckerIds: ["safety", "concurrency", "build", "test"],
                failedCheckerIds: []
            )
        ]
        let scores = await refiner.computeWeightedScores(
            projectMetadata: ["test-project": metadata]
        )
        #expect(abs((scores["test-project"] ?? 0) - 1.0) < 1e-6)
    }

    @Test("Safety checker failure causes large score drop")
    func safetyFailure() async {
        let refiner = PulseRefiner(writer: writer)
        let metadata = [
            makeMetadata(
                timestamp: makeDate("2026-05-01T10:00:00"),
                passedCheckerIds: ["build", "test", "status"],
                failedCheckerIds: ["safety"]
            )
        ]
        let scores = await refiner.computeWeightedScores(
            projectMetadata: ["test-project": metadata]
        )
        let score = scores["test-project"]!
        // safety weight is 1.0 out of total ~ 1.0 + 0.8 + 0.8 + 0.1 = 2.7
        // fail weight = 1.0, so score = 1.0 - 1.0/2.7 ~ 0.63
        #expect(score < 0.7)
        #expect(score > 0.5)
    }

    @Test("Informational checker failure causes small score drop")
    func informationalFailure() async {
        let refiner = PulseRefiner(writer: writer)
        let metadata = [
            makeMetadata(
                timestamp: makeDate("2026-05-01T10:00:00"),
                passedCheckerIds: ["safety", "concurrency", "build"],
                failedCheckerIds: ["status"]
            )
        ]
        let scores = await refiner.computeWeightedScores(
            projectMetadata: ["test-project": metadata]
        )
        let score = scores["test-project"]!
        // status weight is 0.1 out of total ~ 1.0 + 1.0 + 0.8 + 0.1 = 2.9
        // fail weight = 0.1, score = 1.0 - 0.1/2.9 ~ 0.97
        #expect(score > 0.95)
        #expect(score < 1.0)
    }

    @Test("Multiple runs averaged across metadata entries")
    func averageAcrossRuns() async {
        let refiner = PulseRefiner(writer: writer)
        let metadata = [
            makeMetadata(
                timestamp: makeDate("2026-05-01T10:00:00"),
                passedCheckerIds: ["safety", "build"],
                failedCheckerIds: []
            ),
            makeMetadata(
                timestamp: makeDate("2026-05-02T10:00:00"),
                passedCheckerIds: [],
                failedCheckerIds: ["safety", "build"]
            ),
        ]
        let scores = await refiner.computeWeightedScores(
            projectMetadata: ["test-project": metadata]
        )
        let score = scores["test-project"]!
        // Run 1: score = 1.0 (all pass)
        // Run 2: score = 0.0 (all fail)
        // Average: 0.5
        #expect(abs(score - 0.5) < 1e-6)
    }

    @Test("Empty metadata produces no scores")
    func emptyMetadata() async {
        let refiner = PulseRefiner(writer: writer)
        let scores = await refiner.computeWeightedScores(
            projectMetadata: ["test-project": []]
        )
        #expect(scores["test-project"] == nil)
    }
}
