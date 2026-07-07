import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes
import SwiftCLIKit

@Suite("GroupDetailTUIView")
struct GroupDetailTUIViewTests {

    @Test("Renders group name in header")
    func groupNameInHeader() {
        let (projects, state) = makeGroupState()
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(output.contains("Harbor"))
    }

    @Test("Shows member count and aggregate pass rate")
    func memberCountAndPassRate() {
        let (projects, state) = makeGroupState()
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(output.contains("3 members"))
        #expect(output.contains("%"))
    }

    @Test("Lists member projects")
    func listsMemberProjects() {
        let (projects, state) = makeGroupState()
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(output.contains("appA"))
        #expect(output.contains("appB"))
        #expect(output.contains("appC"))
    }

    @Test("Highlights selected member")
    func highlightsSelectedMember() {
        var (projects, state) = makeGroupState()
        state.handleInput(.arrowDown)
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(output.contains(ANSICodes.reverse))
    }

    @Test("Shows group trend sparkline when snapshots available")
    func groupTrendSparkline() {
        let (projects, state) = makeGroupState()
        let snapshots = [
            DailySnapshot(
                date: Date(timeIntervalSince1970: 1747267200),
                scope: "Harbor",
                gateRuns: 10, passedRuns: 5, failedRuns: 5,
                overrides: 0, calibrations: 0,
                failuresByChecker: [:], overridesByRiskTier: [:]
            ),
            DailySnapshot(
                date: Date(timeIntervalSince1970: 1747353600),
                scope: "Harbor",
                gateRuns: 10, passedRuns: 8, failedRuns: 2,
                overrides: 0, calibrations: 0,
                failuresByChecker: [:], overridesByRiskTier: [:]
            ),
        ]
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: snapshots,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(output.contains("Trend"))
    }

    @Test("Shows no trend message when snapshots unavailable")
    func noTrendMessage() {
        let (projects, state) = makeGroupState()
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(output.contains("No trend data"))
    }

    @Test("Long member names are middle-elided, keeping head and suffix")
    func longMemberNameElided() {
        let projects = [makeProjectSummary(id: "BioFeedbackKitCore", passRate: 0.8)]
        var state = DashboardState(projectIDs: ["BioFeedbackKitCore"])
        state.updateGroups(["Harbor": ["BioFeedbackKitCore"]])
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 60 // nameWidth 16 < 18-char name → must elide
        )
        #expect(output.contains("\u{2026}"))            // middle ellipsis
        #expect(output.contains("Bio"))                 // head preserved
        #expect(output.contains("Core"))                // identity-bearing suffix preserved
        #expect(!output.contains("BioFeedbackKitCore")) // full name does not fit verbatim
    }

    // MARK: - Member table columns

    @Test("Member table header lists the new columns")
    func memberTableHeaderColumns() {
        let (projects, state) = makeGroupState()
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: makePulse(),
            state: state,
            width: 100
        )
        #expect(output.contains("Runs"))
        #expect(output.contains("Ovr"))
        #expect(output.contains("Trajectory"))
    }

    @Test("Member row shows a trajectory direction and an anomaly z-score")
    func memberTrajectoryAndZScore() {
        let (projects, state) = makeGroupState()
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: makePulse(),
            state: state,
            width: 100
        )
        // appA has an improving trajectory; appB has an extreme negative anomaly.
        #expect(output.contains("improving"))
        #expect(output.contains("z3.7"))
    }

    // MARK: - Group status block

    @Test("Group status block shows tier, score, trajectory, validity")
    func groupStatusBlock() {
        let (projects, state) = makeGroupState()
        let snapshots = (0..<6).map { i in
            DailySnapshot(
                date: Date(timeIntervalSince1970: 1_747_267_200 + Double(i) * 86_400),
                scope: "Harbor",
                gateRuns: 10, passedRuns: 5 + i % 2, failedRuns: 5 - i % 2,
                overrides: 0, calibrations: 0,
                failuresByChecker: [:], overridesByRiskTier: [:]
            )
        }
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: snapshots,
            pulse: makePulse(),
            state: state,
            width: 100
        )
        #expect(output.contains("Tier:"))
        #expect(output.contains("Quality Score:"))
        #expect(output.contains("Trajectory:"))
        #expect(output.contains("Validity:"))
        #expect(output.contains("inferred from members"))
    }

    @Test("First member row renders at groupDetailHeaderLines")
    func firstMemberRowLine() {
        let (projects, state) = makeGroupState()
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: makePulse(),
            state: state,
            width: 100
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count > state.groupDetailHeaderLines)
        // Members are listed sorted; the first is appA.
        #expect(lines[state.groupDetailHeaderLines].contains("appA"))
    }

    // MARK: - Helpers

    private func makePulse() -> InstitutionalPulse {
        let trajectories = [
            ProjectTrajectory(
                projectID: "appA", slope: 0.05, intercept: 0.5, rSquared: 0.8,
                sampleSize: 12, validity: .preliminary, direction: .improving
            ),
        ]
        let anomalies = [
            StatisticalAnomaly(
                metric: "passRate", observedValue: 0.4, expectedValue: 0.8,
                zScore: -3.7, severity: .extreme,
                date: Date(timeIntervalSince1970: 1_747_267_200),
                scope: "appB", direction: .negative, baselineValidity: .valid
            ),
        ]
        let stats = PulseStatistics(
            totalGateRuns: 30, passedRuns: 20, failedRuns: 10,
            totalOverrides: 0, totalCalibrations: 0,
            overridesByRiskTier: [:], failuresByChecker: [:],
            rootCauseDistribution: [:], failedStepDistribution: [:],
            meanConsistencyScore: nil, corpusTrends: [], projectTrends: [:],
            anomalies: anomalies, corpusSnapshots: [], projectSnapshots: [:],
            weightedScores: ["appA": 0.9, "appB": 0.7, "appC": 0.95]
        )
        return InstitutionalPulse(
            windowStart: Date(timeIntervalSince1970: 1_747_180_800),
            windowEnd: Date(timeIntervalSince1970: 1_747_612_800),
            weekLabel: "2026-W20",
            projects: ["appA", "appB", "appC"],
            statistics: stats,
            violationClusters: [], proposedPolicyUpdates: [], calibrationSummaries: [],
            narrative: nil,
            generatedAt: Date(timeIntervalSince1970: 1_747_612_800),
            projectTiers: ["appA": .active, "appB": .active, "appC": .baseline],
            projectTrajectories: trajectories
        )
    }

    private func makeGroupState() -> ([ProjectSummary], DashboardState) {
        let projects = [
            makeProjectSummary(id: "appA", passRate: 0.8),
            makeProjectSummary(id: "appB", passRate: 0.6),
            makeProjectSummary(id: "appC", passRate: 1.0),
        ]
        var state = DashboardState(projectIDs: ["appA", "appB", "appC"])
        state.updateGroups(["Harbor": ["appA", "appB", "appC"]])
        return (projects, state)
    }
}

private func makeProjectSummary(
    id: String,
    passRate: Double,
    runCount: Int = 10
) -> ProjectSummary {
    let latestPassed = passRate > 0.5
    let passingRunCount = Int((Double(runCount) * passRate).rounded())
    let runs = (0..<runCount).map { i in
        let runPasses = latestPassed
            ? i >= (runCount - passingRunCount)
            : i < passingRunCount
        let results = [
            CheckResult(
                checkerId: "safety",
                status: runPasses ? .passed : .failed,
                diagnostics: [],
                duration: .milliseconds(100)
            ),
        ]
        return TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: id,
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + i * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: results,
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
    return ProjectSummary.compute(projectID: id, from: runs, lifecycle: .active)
}
