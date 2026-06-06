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
            groupID: "Narbis",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(output.contains("Narbis"))
    }

    @Test("Shows member count and aggregate pass rate")
    func memberCountAndPassRate() {
        let (projects, state) = makeGroupState()
        let output = GroupDetailTUIView.render(
            groupID: "Narbis",
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
            groupID: "Narbis",
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
            groupID: "Narbis",
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
                scope: "Narbis",
                gateRuns: 10, passedRuns: 5, failedRuns: 5,
                overrides: 0, calibrations: 0,
                failuresByChecker: [:], overridesByRiskTier: [:]
            ),
            DailySnapshot(
                date: Date(timeIntervalSince1970: 1747353600),
                scope: "Narbis",
                gateRuns: 10, passedRuns: 8, failedRuns: 2,
                overrides: 0, calibrations: 0,
                failuresByChecker: [:], overridesByRiskTier: [:]
            ),
        ]
        let output = GroupDetailTUIView.render(
            groupID: "Narbis",
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
            groupID: "Narbis",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(output.contains("No trend data"))
    }

    // MARK: - Helpers

    private func makeGroupState() -> ([ProjectSummary], DashboardState) {
        let projects = [
            makeProjectSummary(id: "appA", passRate: 0.8),
            makeProjectSummary(id: "appB", passRate: 0.6),
            makeProjectSummary(id: "appC", passRate: 1.0),
        ]
        var state = DashboardState(projectIDs: ["appA", "appB", "appC"])
        state.updateGroups(["Narbis": ["appA", "appB", "appC"]])
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
