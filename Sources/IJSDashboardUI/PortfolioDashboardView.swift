// PortfolioDashboardView.swift
// IJSDashboardUI
//
// The SwiftUI host for the portfolio scene. It renders the SAME PortfolioScene
// Node the terminal will render — via SwiftGUIKit's SwiftUIRenderer — so this is
// the native surface of one scene, not a parallel UI.

#if canImport(SwiftUI)
import SwiftUI
import SwiftGUIKit
import SwiftGUIKitSwiftUI
import IJSDashboardCore
import CorpusKit

/// A native window body rendering the IJS portfolio overview.
public struct PortfolioDashboardView: View {
    /// The cross-project rollup.
    let portfolio: PortfolioSummary
    /// The per-project summaries.
    let projects: [ProjectSummary]
    /// The latest institutional pulse, if available.
    let pulse: InstitutionalPulse?
    /// Per-project recent daily pass rates for the health-timeline column.
    var health: [String: [Double]] = [:]
    /// Group memberships (group ID → member project IDs) for the expandable rows.
    var groups: [String: [String]] = [:]

    /// Creates the portfolio dashboard view.
    public init(portfolio: PortfolioSummary, projects: [ProjectSummary],
                pulse: InstitutionalPulse?, health: [String: [Double]] = [:],
                groups: [String: [String]] = [:]) {
        self.portfolio = portfolio
        self.projects = projects
        self.pulse = pulse
        self.health = health
        self.groups = groups
    }

    private let renderer = SwiftUIRenderer()

    /// Worst checkers enriched with aggregate pass rate and pulse failure counts.
    private var worstCheckerStats: [(checker: String, passRate: Double, failures: Int)] {
        PulseAnalytics.worstCheckerStats(
            worst: portfolio.worstCheckers,
            projects: projects,
            failuresByChecker: pulse?.statistics.failuresByChecker ?? [:]
        )
    }

    /// Each group's latest-day pass rate and total run count, name-sorted.
    private var groupSummaries: [(name: String, passRate: Double, runs: Int)] {
        (pulse?.groupSnapshots ?? [:]).compactMap { name, snapshots in
            guard let latest = snapshots.max(by: { $0.date < $1.date }) else { return nil }
            let rate = PulseAnalytics.passRatePercent(passed: latest.passedRuns, total: latest.gateRuns)
            let runs = snapshots.reduce(0) { $0 + $1.gateRuns }
            return (name, rate, runs)
        }
        .sorted { $0.name < $1.name }
    }

    /// The dashboard view body.
    public var body: some View {
        // A native composition: the header and analytical sections come from the
        // shared SwiftGUIKit scene; the projects table is a native, sortable,
        // resizable `Table`; the narrative is native Markdown. The page scrolls as
        // a whole, and the table gets a bounded height so it doesn't collapse.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("IJS Portfolio Dashboard").font(.title2.bold())

                renderer.view(for: PortfolioScene.headerScene(portfolio: portfolio, pulse: pulse))

                ResizableHeight(initial: 420) {
                    ProjectsTableView(projects: projects, anomalies: pulse?.statistics.anomalies ?? [],
                                      health: health, groups: groups)
                }

                WorstCheckersTable(stats: worstCheckerStats)

                if let snapshots = pulse?.statistics.corpusSnapshots, !snapshots.isEmpty {
                    // No fixed height: EditorialChartView hardcodes its own plot
                    // height (~300pt + furniture); constraining it smaller makes it
                    // draw past its frame onto the next section.
                    CorpusTrendChartView(snapshots: snapshots)
                }

                TierCountsView(tiers: Array((pulse?.projectTiers ?? [:]).values))
                TrajectoryCountsView(directions: pulse?.projectTrajectories?.map(\.direction) ?? [])
                TopMoversTable(movers: pulse?.projectTrajectories?.map { ($0.projectID, $0.slope) } ?? [])
                GroupsTable(groups: groupSummaries)

                if let clusters = pulse?.violationClusters, !clusters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Violation Clusters").font(.headline)
                        ResizableHeight(initial: 240) {
                            ClustersTableView(clusters: clusters)
                        }
                    }
                }

                if let narrative = pulse?.narrative,
                   !narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Narrative").font(.headline)
                        NarrativeMarkdownView(markdown: narrative)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
#endif
