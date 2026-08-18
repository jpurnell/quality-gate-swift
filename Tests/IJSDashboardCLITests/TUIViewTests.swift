import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
@testable import IJSSensor
import IJSAggregator
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
            allRuns: [:],
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
            allRuns: [:],
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
            allRuns: [:],
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
            allRuns: [:],
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
            runs: [],
            state: state,
            width: 80
        )
        #expect(output.contains("quality-gate-swift"))
    }

    @Test("Detail summary shows the product-composition orientation section")
    func detailOrientationSection() {
        var summary = makeProjectSummary(id: "IconquerCore", passRate: 0.9)
        summary.orientation = ModuleOrientationCard(
            moduleID: "IconquerCore",
            whatItDoes: "Core game logic and models.",
            why: "A foundational library — 2 packages build on it.",
            dependsOn: [],
            reliedOnBy: ["IconquerApp", "IconquerCLI"],
            role: "foundation library",
            source: .template,
            generatedAt: Date(timeIntervalSince1970: 1_777_536_311)
        )
        var state = DashboardState(projectIDs: ["IconquerCore"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(project: summary, trends: [], runs: [], state: state, width: 100)
        #expect(output.contains("Orientation"))
        #expect(output.contains("What it does: Core game logic and models."))
        #expect(output.contains("foundation library"))
        #expect(output.contains("Relied on by: IconquerApp, IconquerCLI"))
    }

    /// Builds a census the same way production does — through the metadata.
    private func makeCensus(owners: [String]) -> WriterCensus {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = owners.map { owner in
            CheckResultMetadata(
                projectID: "fixture",
                timestamp: now,
                environment: .local,
                decisionOwner: owner,
                results: [],
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil,
                host: "\(owner)-machine.local")
        }
        return WriterCensus.census(of: metadata, now: now)
    }

    @Test("Detail overview surfaces the second-writer standing warning")
    func detailMultiWriterWarning() {
        var summary = makeProjectSummary(id: "shared-project", passRate: 0.9)
        summary.writerCensus = makeCensus(owners: ["jpurnell", "contributor"])
        var state = DashboardState(projectIDs: ["shared-project"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary, trends: [], runs: [], state: state, width: 100)
        #expect(output.contains("MULTI-WRITER"))
        #expect(output.contains("contributor, jpurnell"))
        #expect(output.contains("Phase 3 controls required"))
    }

    @Test("Detail overview stays quiet for a single-writer project")
    func detailSingleWriterQuiet() {
        var summary = makeProjectSummary(id: "solo-project", passRate: 0.9)
        summary.writerCensus = makeCensus(owners: ["jpurnell"])
        var state = DashboardState(projectIDs: ["solo-project"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary, trends: [], runs: [], state: state, width: 100)
        #expect(!output.contains("MULTI-WRITER"))
    }

    @Test("Detail overview renders the baseline debt burn-down when a ledger is in play")
    func detailBaselineBurnDown() {
        var summary = makeProjectSummary(id: "adopted-project", passRate: 0.9)
        summary.baselineBurnDown = [
            BaselineSnapshot(baselined: 42, expired: 0, newFindings: 0),
            BaselineSnapshot(baselined: 38, expired: 1, newFindings: 0),
            BaselineSnapshot(baselined: 31, expired: 2, newFindings: 1),
        ]
        var state = DashboardState(projectIDs: ["adopted-project"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary, trends: [], runs: [], state: state, width: 100)
        #expect(output.contains("Baseline:"))
        #expect(output.contains("31 debt(s)"))
        #expect(output.contains("2 EXPIRED"))
        #expect(output.contains("42 → 38 → 31"))
    }

    @Test("Detail overview shows no baseline line without a ledger")
    func detailNoBaselineLine() {
        let summary = makeProjectSummary(id: "unadopted-project", passRate: 0.9)
        var state = DashboardState(projectIDs: ["unadopted-project"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary, trends: [], runs: [], state: state, width: 100)
        #expect(!output.contains("Baseline:"))
    }

    @Test("Detail overview tab shows status and pass rate")
    func detailOverviewTab() {
        let summary = makeProjectSummary(id: "test", passRate: 0.9)
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            runs: [],
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
        state.handleInput(.arrowRight)
        #expect(state.selectedTab == .checkers)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            runs: [],
            state: state,
            width: 80
        )
        #expect(output.contains("safety"))
        #expect(output.contains("build"))
    }

    @Test("Summary tab shows the trend sparkline section")
    func summaryTabShowsTrends() {
        let summary = makeProjectSummary(id: "test", passRate: 1.0)
        let trends = makeTrends()
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)
        #expect(state.selectedTab == .summary)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: trends,
            runs: [],
            state: state,
            width: 80
        )
        #expect(output.contains("Pass Rate Trend"))
    }

    @Test("Summary tab stacks summary, trends, and status sections in one frame")
    func summaryTabStacksSections() {
        let summary = makeProjectSummary(id: "test", passRate: 0.9)
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: makeTrends(),
            runs: [],
            state: state,
            width: 80
        )
        #expect(output.contains("Summary"))
        #expect(output.contains("Pass Rate Trend"))
        #expect(output.contains("Tier:"))
        #expect(output.contains("Override Tier:"))
    }

    @Test("Tab bar renders on the hit-tested bar line")
    func tabBarOnExpectedLine() {
        let summary = makeProjectSummary(id: "test", passRate: 1.0)
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)
        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            runs: [],
            state: state,
            width: 80
        )
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        #expect(lines.count > DetailTabBar.barLineIndex)
        let barLine = lines[DetailTabBar.barLineIndex]
        #expect(barLine.contains("Summary"))
        #expect(barLine.contains("Checkers"))
    }

    @Test("Detail tab bar shows exactly Summary and Checkers")
    func detailTabIndicators() {
        let summary = makeProjectSummary(id: "test", passRate: 1.0)
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            runs: [],
            state: state,
            width: 80
        )
        #expect(output.contains("Summary"))
        #expect(output.contains("Checkers"))
        // The former standalone tabs are gone from the tab bar.
        #expect(!output.contains("Overview"))
    }
    // MARK: - Sunset Lifecycle

    @Test("Portfolio view shows active and sunset counts in status line")
    func portfolioSunsetCounts() {
        let active = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.8),
        ]
        let sunset = [
            makeProjectSummary(id: "gamma", passRate: 0.0, lifecycle: .sunset),
        ]
        let projects = active + sunset
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: active.map(\.projectID))
        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: [:],
            state: state,
            width: 80
        )
        #expect(output.contains("2 active"))
        #expect(output.contains("1 sunset"))
    }

    @Test("Portfolio view only shows active projects in main table")
    func portfolioActiveOnly() {
        let active = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
        ]
        let sunset = [
            makeProjectSummary(id: "retired-proj", passRate: 0.0, lifecycle: .sunset),
        ]
        let projects = active + sunset
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: active.map(\.projectID))
        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: [:],
            state: state,
            width: 80
        )
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let headerIdx = lines.firstIndex(where: { $0.contains("Project") && $0.contains("Status") })
        let sunsetIdx = lines.firstIndex(where: { $0.contains("Sunset") })
        if let headerIdx, let sunsetIdx {
            let mainTableLines = lines[headerIdx..<sunsetIdx].joined()
            #expect(!mainTableLines.contains("retired-proj"))
        }
        #expect(output.contains("retired-proj"))
    }

    @Test("Portfolio view shows sunset section when sunset projects exist")
    func portfolioSunsetSection() {
        let sunset = [
            makeProjectSummary(id: "old-proj", passRate: 0.0, lifecycle: .sunset),
        ]
        let active = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
        ]
        let projects = active + sunset
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: active.map(\.projectID))
        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: [:],
            state: state,
            width: 80
        )
        #expect(output.contains("Sunset"))
        #expect(output.contains("old-proj"))
    }

    @Test("Portfolio view sorts by pass rate when sort key is passRate")
    func portfolioSortsByPassRate() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.3),
            makeProjectSummary(id: "gamma", passRate: 0.7),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        var state = DashboardState(projectIDs: ["alpha", "beta", "gamma"])
        // Cycle to passRate sort key: name → status → passRate
        state.handleInput(.cycleSort) // → .status
        state.handleInput(.cycleSort) // → .passRate (ascending)
        #expect(state.sortKey == .passRate)
        let sortedIDs = PortfolioTUIView.sortedActiveIDs(
            from: projects, sortKey: state.sortKey, sortAscending: state.sortAscending
        )
        state.updateProjectIDs(sortedIDs)

        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: [:],
            state: state,
            width: 80
        )

        // Strip ANSI codes to get plain text for ordering check
        let plain = output.replacingOccurrences(of: "\u{001B}\\[[^m]*m", with: "", options: .regularExpression)
        if let betaRange = plain.range(of: "beta"),
           let gammaRange = plain.range(of: "gamma"),
           let alphaRange = plain.range(of: "alpha") {
            // Ascending passRate: beta (0.3) < gamma (0.7) < alpha (1.0)
            #expect(betaRange.lowerBound < gammaRange.lowerBound)
            #expect(gammaRange.lowerBound < alphaRange.lowerBound)
        }
    }

    @Test("Portfolio view hides sunset section when no sunset projects")
    func portfolioNoSunsetSection() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.8),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: ["alpha", "beta"])
        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: [:],
            state: state,
            width: 80
        )
        #expect(!output.contains("Sunset"))
    }

    // MARK: - Compact Pulse Header

    @Test("Portfolio view shows compact pulse stats before project table")
    func portfolioCompactPulseHeader() throws {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.8),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: ["alpha", "beta"])

        let stats = PulseStatistics(
            totalGateRuns: 688,
            passedRuns: 132,
            failedRuns: 556,
            totalOverrides: 0,
            totalCalibrations: 0,
            overridesByRiskTier: [:],
            failuresByChecker: [:],
            rootCauseDistribution: [:],
            failedStepDistribution: [:],
            meanConsistencyScore: 0.85,
            corpusTrends: [],
            projectTrends: [:],
            anomalies: [],
            corpusSnapshots: [],
            projectSnapshots: [:]
        )
        let pulse = InstitutionalPulse(
            windowStart: Date(timeIntervalSince1970: 1747267200),
            windowEnd: Date(timeIntervalSince1970: 1747872000),
            weekLabel: "W20",
            projects: ["alpha", "beta"],
            statistics: stats,
            violationClusters: [],
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: Date(timeIntervalSince1970: 1747872000)
        )

        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: [:],
            state: state,
            width: 80,
            pulse: pulse
        )

        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        // Find indices of the compact pulse line and the project table header
        let pulseLineIdx = lines.firstIndex(where: { $0.contains("Pulse") && $0.contains("688") })
        let tableHeaderIdx = lines.firstIndex(where: { $0.contains("Project") && $0.contains("Status") })

        let pulseIdx = try #require(pulseLineIdx, "Expected compact pulse stats line to be present")
        let tableIdx = try #require(tableHeaderIdx, "Expected project table header to be present")

        #expect(pulseIdx < tableIdx, "Compact pulse stats should appear before the project table header")
    }

    // MARK: - Scroll Clipping

    @Test("Detail checkers tab with many checkers exceeds typical terminal height")
    func detailCheckersOverflow() {
        let checkerRates = Dictionary(uniqueKeysWithValues:
            (0..<25).map { ("checker_\(twoDigits($0))", Double($0) / 24.0) }
        )
        let summary = makeProjectSummary(
            id: "overflow-test",
            passRate: 0.8,
            checkerRates: checkerRates
        )
        var state = DashboardState(projectIDs: ["overflow-test"])
        state.handleInput(.enter)
        state.handleInput(.arrowRight)

        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            runs: [],
            state: state,
            width: 80
        )
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
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
        state.handleInput(.arrowRight)

        let width = 80
        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            runs: [],
            state: state,
            width: width
        )
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (idx, line) in lines.enumerated() {
            let visLen = ANSIStringMetrics.visibleLength(String(line))
            #expect(visLen <= width, "Line \(idx) visible length \(visLen) exceeds width \(width)")
        }
    }
    // MARK: - Sort-Aware Project IDs

    @Test("sortedActiveIDs returns IDs in pass rate order")
    func sortedActiveIDsByPassRate() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.3),
            makeProjectSummary(id: "gamma", passRate: 0.7),
        ]
        let ids = PortfolioTUIView.sortedActiveIDs(
            from: projects, sortKey: .passRate, sortAscending: true
        )
        #expect(ids == ["beta", "gamma", "alpha"])
    }

    @Test("sortedActiveIDs excludes sunset projects")
    func sortedActiveIDsExcludesSunset() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.5, lifecycle: .sunset),
        ]
        let ids = PortfolioTUIView.sortedActiveIDs(
            from: projects, sortKey: .name, sortAscending: true
        )
        #expect(ids == ["alpha"])
    }

    @Test("drill-in after sort selects correct project")
    func drillInAfterSort() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.3),
            makeProjectSummary(id: "gamma", passRate: 0.7),
        ]
        var state = DashboardState(projectIDs: ["alpha", "beta", "gamma"])

        state.handleInput(.cycleSort)
        state.handleInput(.cycleSort)
        let ids = PortfolioTUIView.sortedActiveIDs(
            from: projects, sortKey: state.sortKey, sortAscending: state.sortAscending
        )
        state.updateProjectIDs(ids)

        #expect(state.sortKey == .passRate)
        // ids is [beta, gamma, alpha] (ascending pass rate)
        #expect(ids == ["beta", "gamma", "alpha"])
        // selection preserved on "alpha" which is now at index 2
        #expect(state.selectedProjectID == "alpha")
        // navigate to first row, then drill in — should get beta
        state.handleInput(.arrowUp)
        state.handleInput(.arrowUp)
        #expect(state.selectedIndex == 0)
        state.handleInput(.enter)
        #expect(state.selectedProjectID == "beta")
        #expect(state.currentView == .projectDetail)
    }
    // MARK: - Status Section (within Summary tab)

    @Test("Summary tab renders the Status section title")
    func statusSectionTitle() {
        let project = makeProjectSummary(id: "test", passRate: 0.8)
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter)
        let output = ProjectDetailTUIView.render(
            project: project,
            trends: makeTrends(),
            runs: [],
            state: state,
            width: 80
        )
        #expect(output.contains("Status"))
    }

    @Test("Summary tab renders tier and quality score labels without navigation")
    func statusSectionRendersContent() {
        let project = makeProjectSummary(id: "test", passRate: 0.8)
        var state = DashboardState(projectIDs: ["test"])
        state.handleInput(.enter) // summary tab shows the status section directly
        let output = ProjectDetailTUIView.render(
            project: project,
            trends: makeTrends(),
            runs: [],
            state: state,
            width: 80
        )
        #expect(output.contains("Tier:"))
        #expect(output.contains("Quality Score:"))
        #expect(output.contains("Override Tier:"))
    }

    // MARK: - Group Rendering

    @Test("Portfolio view renders group header with disclosure arrow")
    func portfolioGroupHeaderDisclosureArrow() {
        let projects = [
            makeProjectSummary(id: "appA", passRate: 0.8),
            makeProjectSummary(id: "appB", passRate: 0.6),
            makeProjectSummary(id: "solo", passRate: 1.0),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        var state = DashboardState(projectIDs: ["appA", "appB", "solo"])
        state.updateGroups(["MyGroup": ["appA", "appB"]])
        let allRuns: [String: [TimestampedRun]] = [:]

        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: allRuns,
            state: state,
            width: 80
        )
        #expect(output.contains("\u{25B6}") || output.contains("\u{25BC}"))
        #expect(output.contains("MyGroup"))
    }

    @Test("Portfolio view middle-elides a long group name but keeps arrow and count")
    func portfolioGroupNameElided() {
        let longID = "SuperLongPlatformFrameworkGroup"
        let projects = [
            makeProjectSummary(id: "m1", passRate: 0.8),
            makeProjectSummary(id: "m2", passRate: 0.6),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        var state = DashboardState(projectIDs: ["m1", "m2"])
        state.updateGroups([longID: ["m1", "m2"]])

        let output = PortfolioTUIView.render(
            portfolio: portfolio, projects: projects, allRuns: [:], state: state, width: 80
        )
        let plain = ANSIStringMetrics.plainText(output)
        // Name too long for the column → ellipsis, but arrow, count, and the
        // identity-bearing suffix survive; the full name never appears uncut.
        #expect(plain.contains("…"))
        #expect(plain.contains("(2)"))
        #expect(plain.contains("Group"))
        #expect(!plain.contains(longID))
        #expect(plain.contains("\u{25B6}") || plain.contains("\u{25BC}"))
    }

    @Test("Portfolio view leaves a short group name unelided")
    func portfolioShortGroupNameUnchanged() {
        let projects = [
            makeProjectSummary(id: "m1", passRate: 0.8),
            makeProjectSummary(id: "m2", passRate: 0.6),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        var state = DashboardState(projectIDs: ["m1", "m2"])
        state.updateGroups(["Harbor": ["m1", "m2"]])

        let output = PortfolioTUIView.render(
            portfolio: portfolio, projects: projects, allRuns: [:], state: state, width: 80
        )
        let plain = ANSIStringMetrics.plainText(output)
        #expect(plain.contains("Harbor (2)"))
        #expect(!plain.contains("Na…"))
    }

    @Test("Portfolio view shows expanded group members indented")
    func portfolioExpandedGroupIndented() {
        let projects = [
            makeProjectSummary(id: "appA", passRate: 0.8),
            makeProjectSummary(id: "appB", passRate: 0.6),
            makeProjectSummary(id: "solo", passRate: 1.0),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        var state = DashboardState(projectIDs: ["appA", "appB", "solo"])
        state.updateGroups(["MyGroup": ["appA", "appB"]])
        state.toggleGroup("MyGroup")
        let allRuns: [String: [TimestampedRun]] = [:]

        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: allRuns,
            state: state,
            width: 80
        )
        #expect(output.contains("\u{25BC}"))
        #expect(output.contains("appA"))
        #expect(output.contains("appB"))
    }

    @Test("Portfolio view collapsed group hides members")
    func portfolioCollapsedGroupHidesMembers() {
        let projects = [
            makeProjectSummary(id: "appA", passRate: 0.8),
            makeProjectSummary(id: "appB", passRate: 0.6),
            makeProjectSummary(id: "solo", passRate: 1.0),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        var state = DashboardState(projectIDs: ["appA", "appB", "solo"])
        state.updateGroups(["MyGroup": ["appA", "appB"]])
        let allRuns: [String: [TimestampedRun]] = [:]

        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: allRuns,
            state: state,
            width: 80
        )
        #expect(output.contains("MyGroup"))
        // Members should not appear as individual rows when collapsed
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let projectLines = lines.filter { $0.contains("appA") || $0.contains("appB") }
        #expect(projectLines.isEmpty)
    }

    @Test("Portfolio view ungrouped projects render without indent")
    func portfolioUngroupedNoIndent() {
        let projects = [
            makeProjectSummary(id: "appA", passRate: 0.8),
            makeProjectSummary(id: "solo", passRate: 1.0),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        var state = DashboardState(projectIDs: ["appA", "solo"])
        state.updateGroups(["G": ["appA"]])
        let allRuns: [String: [TimestampedRun]] = [:]

        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: allRuns,
            state: state,
            width: 80
        )
        #expect(output.contains("solo"))
    }
}

// MARK: - Test Helpers

private func makeProjectSummary(
    id: String,
    passRate: Double,
    runCount: Int = 10,
    checkerRates: [String: Double] = ["safety": 1.0],
    overrides: Int = 0,
    lifecycle: ProjectLifecycle = .active
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
    return ProjectSummary.compute(projectID: id, from: runs, lifecycle: lifecycle)
}

private func makeTrends() -> [TrendPoint] {
    [
        TrendPoint(date: Date(timeIntervalSince1970: 1747267200), value: 0.5),
        TrendPoint(date: Date(timeIntervalSince1970: 1747353600), value: 0.75),
        TrendPoint(date: Date(timeIntervalSince1970: 1747440000), value: 0.9),
        TrendPoint(date: Date(timeIntervalSince1970: 1747526400), value: 1.0),
    ]
}

/// A two-digit, zero-padded decimal — `5` becomes `"05"`.
///
/// Not `String(format: "%02d")`: that bridges to the C printf ABI, where an argument-type
/// mistake is a runtime `SIGSEGV` rather than a compile error, and the gate forbids it. Not
/// `IntegerFormatStyle` either — that is locale-aware, and a fixture date string must be the
/// same bytes under every locale the suite might run in.
private func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
}
