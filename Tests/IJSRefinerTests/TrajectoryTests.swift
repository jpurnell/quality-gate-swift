import Testing
import Foundation
import QualityGateTypes
@testable import IJSRefiner
import IJSSensor
import IJSAggregator

@Suite("PulseRefiner Trajectory")
struct TrajectoryTests {

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

    @Test("Improving trend produces positive slope")
    func improvingTrend() async throws {
        let refiner = PulseRefiner(writer: writer)
        // Early runs fail safety, later runs pass everything
        let metadata: [CheckResultMetadata] = [
            makeMetadata(timestamp: makeDate("2026-05-01T10:00:00"),
                         passedCheckerIds: ["build"],
                         failedCheckerIds: ["safety", "concurrency"]),
            makeMetadata(timestamp: makeDate("2026-05-02T10:00:00"),
                         passedCheckerIds: ["build", "safety"],
                         failedCheckerIds: ["concurrency"]),
            makeMetadata(timestamp: makeDate("2026-05-03T10:00:00"),
                         passedCheckerIds: ["build", "safety", "concurrency"],
                         failedCheckerIds: []),
        ]
        let projectMetadata = ["test-project": metadata]
        let trajectories = await refiner.computeTrajectories(
            projectWeightedScores: ["test-project": 0.8],
            projectSnapshots: [:],
            projectMetadata: projectMetadata
        )
        let trajectory = try #require(trajectories.first { $0.projectID == "test-project" })
        #expect(trajectory.slope > 0)
        #expect(trajectory.direction == .improving)
    }

    @Test("Declining trend produces negative slope")
    func decliningTrend() async throws {
        let refiner = PulseRefiner(writer: writer)
        // Start with all passing, end with failures
        let metadata: [CheckResultMetadata] = [
            makeMetadata(timestamp: makeDate("2026-05-01T10:00:00"),
                         passedCheckerIds: ["safety", "concurrency", "build"],
                         failedCheckerIds: []),
            makeMetadata(timestamp: makeDate("2026-05-02T10:00:00"),
                         passedCheckerIds: ["build"],
                         failedCheckerIds: ["safety"]),
            makeMetadata(timestamp: makeDate("2026-05-03T10:00:00"),
                         passedCheckerIds: [],
                         failedCheckerIds: ["safety", "concurrency", "build"]),
        ]
        let projectMetadata = ["test-project": metadata]
        let trajectories = await refiner.computeTrajectories(
            projectWeightedScores: ["test-project": 0.5],
            projectSnapshots: [:],
            projectMetadata: projectMetadata
        )
        let trajectory = try #require(trajectories.first { $0.projectID == "test-project" })
        #expect(trajectory.slope < 0)
        #expect(trajectory.direction == .declining)
    }

    @Test("Insufficient data with fewer than 2 runs")
    func insufficientData() async throws {
        let refiner = PulseRefiner(writer: writer)
        let metadata: [CheckResultMetadata] = [
            makeMetadata(timestamp: makeDate("2026-05-01T10:00:00"),
                         passedCheckerIds: ["safety"],
                         failedCheckerIds: []),
        ]
        let projectMetadata = ["test-project": metadata]
        let trajectories = await refiner.computeTrajectories(
            projectWeightedScores: ["test-project": 1.0],
            projectSnapshots: [:],
            projectMetadata: projectMetadata
        )
        let trajectory = try #require(trajectories.first { $0.projectID == "test-project" })
        #expect(trajectory.direction == .insufficient)
        #expect(trajectory.sampleSize == 1)
    }

    @Test("Inflection detected with 6+ data points and direction change")
    func inflectionDetection() async throws {
        let refiner = PulseRefiner(writer: writer)
        // First half improving (fail -> pass), second half declining (pass -> fail)
        let metadata: [CheckResultMetadata] = [
            // First half: improving
            makeMetadata(timestamp: makeDate("2026-05-01T10:00:00"),
                         passedCheckerIds: [],
                         failedCheckerIds: ["safety", "concurrency"]),
            makeMetadata(timestamp: makeDate("2026-05-02T10:00:00"),
                         passedCheckerIds: ["safety"],
                         failedCheckerIds: ["concurrency"]),
            makeMetadata(timestamp: makeDate("2026-05-03T10:00:00"),
                         passedCheckerIds: ["safety", "concurrency"],
                         failedCheckerIds: []),
            // Second half: declining
            makeMetadata(timestamp: makeDate("2026-05-04T10:00:00"),
                         passedCheckerIds: ["safety"],
                         failedCheckerIds: ["concurrency"]),
            makeMetadata(timestamp: makeDate("2026-05-05T10:00:00"),
                         passedCheckerIds: [],
                         failedCheckerIds: ["safety", "concurrency"]),
            makeMetadata(timestamp: makeDate("2026-05-06T10:00:00"),
                         passedCheckerIds: [],
                         failedCheckerIds: ["safety", "concurrency"]),
        ]
        let projectMetadata = ["test-project": metadata]
        let trajectories = await refiner.computeTrajectories(
            projectWeightedScores: ["test-project": 0.5],
            projectSnapshots: [:],
            projectMetadata: projectMetadata
        )
        let trajectory = try #require(trajectories.first { $0.projectID == "test-project" })
        #expect(trajectory.sampleSize == 6)
        let recentSlope = try #require(trajectory.recentSlope)
        // The recent half is declining, so recentSlope should be negative
        #expect(recentSlope < 0)
    }
}
