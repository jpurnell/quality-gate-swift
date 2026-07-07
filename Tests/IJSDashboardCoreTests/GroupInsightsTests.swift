import Testing
import Foundation
@testable import IJSDashboardCore
@testable import IJSSensor

@Suite("GroupInsights")
struct GroupInsightsTests {

    /// Builds a snapshot with a controlled pass rate (`passed`/`runs`) on a fixed day.
    private func snapshot(day: Int, runs: Int, passed: Int) -> DailySnapshot {
        DailySnapshot(
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400),
            scope: "group",
            gateRuns: runs,
            passedRuns: passed,
            failedRuns: runs - passed,
            overrides: 0,
            calibrations: 0,
            failuresByChecker: [:],
            overridesByRiskTier: [:]
        )
    }

    // MARK: - groupTrajectory

    @Test("Rising pass rate yields an improving trajectory")
    func trajectoryImproving() {
        let snaps = (0..<10).map { i in snapshot(day: i, runs: 10, passed: min(10, 3 + i)) }
        let traj = GroupInsights.groupTrajectory(groupID: "G", snapshots: snaps)
        #expect(traj.projectID == "G")
        #expect(traj.slope > 0)
        #expect(traj.direction == .improving)
        #expect(traj.sampleSize == 10)
    }

    @Test("Falling pass rate yields a declining trajectory")
    func trajectoryDeclining() {
        let snaps = (0..<10).map { i in snapshot(day: i, runs: 10, passed: max(0, 10 - i)) }
        let traj = GroupInsights.groupTrajectory(groupID: "G", snapshots: snaps)
        #expect(traj.slope < 0)
        #expect(traj.direction == .declining)
    }

    @Test("Flat pass rate yields a stable trajectory")
    func trajectoryStable() {
        let snaps = (0..<10).map { i in snapshot(day: i, runs: 10, passed: 7) }
        let traj = GroupInsights.groupTrajectory(groupID: "G", snapshots: snaps)
        #expect(abs(traj.slope) < 1e-6)
        #expect(traj.direction == .stable)
    }

    @Test("Fewer than two points is insufficient")
    func trajectoryInsufficient() {
        let traj = GroupInsights.groupTrajectory(groupID: "G", snapshots: [snapshot(day: 0, runs: 10, passed: 5)])
        #expect(traj.direction == .insufficient)
        #expect(traj.validity == .insufficient)
        #expect(traj.sampleSize == 1)
    }

    @Test("Validity follows sample-size thresholds")
    func trajectoryValidity() {
        let few = (0..<5).map { i in snapshot(day: i, runs: 10, passed: 5 + (i % 2)) }
        #expect(GroupInsights.groupTrajectory(groupID: "G", snapshots: few).validity == .preliminary)
        let many = (0..<35).map { i in snapshot(day: i, runs: 10, passed: 5 + (i % 3)) }
        #expect(GroupInsights.groupTrajectory(groupID: "G", snapshots: many).validity == .valid)
    }

    @Test("Empty snapshots do not crash and are insufficient")
    func trajectoryEmpty() {
        let traj = GroupInsights.groupTrajectory(groupID: "G", snapshots: [])
        #expect(traj.direction == .insufficient)
        #expect(traj.sampleSize == 0)
    }

    // MARK: - qualityScore

    @Test("Quality score is the mean of available member weighted scores")
    func qualityScoreFromWeighted() {
        let score = GroupInsights.qualityScore(
            memberIDs: ["a", "b", "c"],
            aggregatePassRate: 0.5,
            weightedScores: ["a": 0.9, "b": 0.7, "c": 0.8]
        )
        #expect(abs(score - 0.8) < 1e-9)
    }

    @Test("Quality score averages only members that have a weighted score")
    func qualityScorePartialWeighted() {
        let score = GroupInsights.qualityScore(
            memberIDs: ["a", "b", "c"],
            aggregatePassRate: 0.1,
            weightedScores: ["a": 0.6, "b": 0.8]
        )
        #expect(abs(score - 0.7) < 1e-9)
    }

    @Test("Quality score falls back to aggregate pass rate when no weighted scores")
    func qualityScoreFallback() {
        let score = GroupInsights.qualityScore(
            memberIDs: ["a", "b"],
            aggregatePassRate: 0.72,
            weightedScores: nil
        )
        #expect(abs(score - 0.72) < 1e-9)
    }

    // MARK: - inferredTier

    @Test("Inferred tier is the most common member tier")
    func inferredTierModal() {
        let tier = GroupInsights.inferredTier(
            memberIDs: ["a", "b", "c"],
            tiers: ["a": .active, "b": .active, "c": .baseline]
        )
        #expect(tier == .active)
    }

    @Test("Inferred tier tie-breaks deterministically by tier order")
    func inferredTierTieBreak() {
        // One each — tie broken toward the earliest ProjectTier.allCases entry.
        let tier = GroupInsights.inferredTier(
            memberIDs: ["a", "b"],
            tiers: ["a": .active, "b": .dormant]
        )
        #expect(tier == .dormant)
    }

    @Test("Inferred tier is nil when no member has a tier")
    func inferredTierNil() {
        #expect(GroupInsights.inferredTier(memberIDs: ["a", "b"], tiers: [:]) == nil)
    }
}
