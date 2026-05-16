import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes
import SwiftCLIKit

@Suite("TUI Views")
struct TUIViewTests {

    // MARK: - Portfolio TUI View

    @Test("Portfolio view renders box-drawn border")
    func portfolioBorder() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.8),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: ["alpha", "beta"])
        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            state: state,
            width: 80
        )
        #expect(output.contains("Portfolio"))
    }

    @Test("Portfolio view highlights selected row")
    func portfolioHighlight() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.8),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        var state = DashboardState(projectIDs: ["alpha", "beta"])
        state.handleInput(.arrowDown)

        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            state: state,
            width: 80
        )
        #expect(output.contains(ANSICodes.reverse))
    }

    @Test("Portfolio view shows pass rate gauges")
    func portfolioGauges() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: ["alpha"])
        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            state: state,
            width: 80
        )
        #expect(output.contains("100%"))
    }

    @Test("Portfolio view shows help bar")
    func portfolioHelpBar() {
        let projects: [ProjectSummary] = []
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: [])
        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            state: state,
            width: 80
        )
        #expect(output.contains("q") || output.contains("Quit"))
    }

    // MARK: - Project Detail TUI View

    @Test("Detail view renders project name")
    func detailProjectName() {
        let summary = makeProjectSummary(id: "quality-gate-swift", passRate: 0.9)
        let trends = makeTrends()
        var state = DashboardState(projectIDs: ["quality-gate-swift"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: trends,
            state: state,
            width: 80
        )
        #expect(output.contains("quality-gate-swift"))
    }

    @Test("Detail overview tab shows status and pass rate")
    func detailOverviewTab() {
        let summary = makeProjectSummary(id: "test", passRate: 0.9)
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            state: state,
            width: 80
        )
        #expect(output.contains("Pass Rate"))
        #expect(output.contains("90%"))
    }

    @Test("Detail checkers tab shows checker breakdown")
    func detailCheckersTab() {
        let summary = makeProjectSummary(
            id: "test",
            passRate: 0.75,
            checkerRates: ["safety": 1.0, "build": 0.5]
        )
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)
        state.handleInput(.tab)
        #expect(state.selectedTab == .checkers)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            state: state,
            width: 80
        )
        #expect(output.contains("safety"))
        #expect(output.contains("build"))
    }

    @Test("Detail trends tab shows sparkline")
    func detailTrendsTab() {
        let summary = makeProjectSummary(id: "test", passRate: 1.0)
        let trends = makeTrends()
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)
        state.handleInput(.tab)
        state.handleInput(.tab)
        #expect(state.selectedTab == .trends)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: trends,
            state: state,
            width: 80
        )
        #expect(output.contains("Pass Rate Trend"))
    }

    @Test("Detail view shows tab indicators")
    func detailTabIndicators() {
        let summary = makeProjectSummary(id: "test", passRate: 1.0)
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            state: state,
            width: 80
        )
        #expect(output.contains("Overview"))
        #expect(output.contains("Checkers"))
        #expect(output.contains("Trends"))
    }
    // MARK: - Scroll Clipping

    @Test("Detail checkers tab with many checkers exceeds typical terminal height")
    func detailCheckersOverflow() {
        let checkerRates = Dictionary(uniqueKeysWithValues:
            (0..<25).map { ("checker_\(String(format: "%02d", $0))", Double($0) / 24.0) }
        )
        let summary = makeProjectSummary(
            id: "overflow-test",
            passRate: 0.8,
            checkerRates: checkerRates
        )
        var state = DashboardState(projectIDs: ["overflow-test"])
        state.handleInput(.enter)
        state.handleInput(.tab)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            state: state,
            width: 80
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count > 24, "25 checkers should produce more lines than a 24-row terminal")
    }

    @Test("Rendered lines fit within specified width")
    func renderedLinesFitWidth() {
        let checkerRates: [String: Double] = [
            "safety": 1.0, "build": 0.85, "concurrency": 0.6,
            "recursion": 0.45, "logging": 0.92,
        ]
        let summary = makeProjectSummary(
            id: "width-test",
            passRate: 0.8,
            checkerRates: checkerRates
        )
        var state = DashboardState(projectIDs: ["width-test"])
        state.handleInput(.enter)
        state.handleInput(.tab)

        let width = 80
        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            state: state,
            width: width
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            let visLen = ANSIStringMetrics.visibleLength(String(line))
            #expect(visLen <= width, "Line \(idx) visible length \(visLen) exceeds width \(width)")
        }
    }
}

// MARK: - Test Helpers

private func makeProjectSummary(
    id: String,
    passRate: Double,
    runCount: Int = 10,
    checkerRates: [String: Double] = ["safety": 1.0],
    overrides: Int = 0
) -> ProjectSummary {
    let latestPassed = passRate > 0.5
    let passingRunCount = Int((Double(runCount) * passRate).rounded())
    let runs = (0..<runCount).map { i in
        let runPasses: Bool
        if latestPassed {
            runPasses = i >= (runCount - passingRunCount)
        } else {
            runPasses = i < passingRunCount
        }
        let results = checkerRates.map { checkerId, rate in
            let checkerPasses = runPasses || (Double(i) / Double(max(runCount, 1)) < rate)
            return CheckResult(
                checkerId: checkerId,
                status: checkerPasses ? .passed : .failed,
                diagnostics: [],
                duration: .milliseconds(100)
            )
        }
        let finalResults: [CheckResult]
        if !runPasses {
            var modified = results
            modified.append(CheckResult(
                checkerId: "_gate",
                status: .failed,
                diagnostics: [],
                duration: .milliseconds(1)
            ))
            finalResults = modified
        } else {
            finalResults = results
        }
        let overridesForRun = i == 0 ? (0..<overrides).map { _ in
            OverrideRecord(
                diagnosticOverride: DiagnosticOverride(ruleId: "test", justification: "test"),
                author: "test",
                riskTier: .operational,
                authorityLevel: .peer
            )
        } : []
        return TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: id,
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + i * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: finalResults,
                overrides: overridesForRun,
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
    return ProjectSummary.compute(projectID: id, from: runs)
}

private func makeTrends() -> [TrendPoint] {
    [
        TrendPoint(date: Date(timeIntervalSince1970: 1747267200), value: 0.5),
        TrendPoint(date: Date(timeIntervalSince1970: 1747353600), value: 0.75),
        TrendPoint(date: Date(timeIntervalSince1970: 1747440000), value: 0.9),
        TrendPoint(date: Date(timeIntervalSince1970: 1747526400), value: 1.0),
    ]
}
