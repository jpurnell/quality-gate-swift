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
    /// Per-project advisory findings for the drill-down inbox.
    var inbox: [String: [InboxFinding]] = [:]
    /// Per-project daily pass-rate trend for the drill-down chart.
    var trends: [String: [TrendPoint]] = [:]

    /// Creates the portfolio dashboard view.
    public init(portfolio: PortfolioSummary, projects: [ProjectSummary],
                pulse: InstitutionalPulse?, health: [String: [Double]] = [:],
                groups: [String: [String]] = [:],
                inbox: [String: [InboxFinding]] = [:],
                trends: [String: [TrendPoint]] = [:]) {
        self.portfolio = portfolio
        self.projects = projects
        self.pulse = pulse
        self.health = health
        self.groups = groups
        self.inbox = inbox
        self.trends = trends
    }

    private let renderer = SwiftUIRenderer()

    /// A sidebar selection: the portfolio overview, or one project's detail.
    private enum SidebarItem: Hashable {
        case overview
        case project(String)
    }

    /// The current sidebar selection, driving the detail pane. Defaults to the
    /// portfolio overview.
    @State private var sidebar: SidebarItem? = .overview

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
        // A sidebar-driven Mac layout: the sidebar lists the projects; the detail
        // pane shows the portfolio overview by default and swaps to a project's
        // detail when one is selected (from the sidebar or the in-page table).
        NavigationSplitView {
            sidebarList
        } detail: {
            detailPane
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    /// The projects sidebar: an Overview item, then each group as a disclosure
    /// section over its members, then the ungrouped projects — consolidated the
    /// same way the overview table groups them.
    @ViewBuilder
    private var sidebarList: some View {
        List(selection: $sidebar) {
            Label("Portfolio Overview", systemImage: "chart.bar.doc.horizontal")
                .tag(SidebarItem.overview)
            Section("Projects") {
                ForEach(groupedSections, id: \.id) { section in
                    DisclosureGroup {
                        ForEach(section.members, id: \.projectID) { project in
                            projectRow(project).contextMenu { rowMenu(project.projectID) }
                        }
                    } label: {
                        Label("\(section.id) (\(section.members.count))", systemImage: "folder")
                    }
                }
                ForEach(ungroupedProjects, id: \.projectID) { project in
                    projectRow(project).contextMenu { rowMenu(project.projectID) }
                }
            }
        }
        .navigationTitle("IJS")
        .frame(minWidth: 200)
    }

    /// One sidebar project row: a status glyph, the ID, and a selection tag.
    @ViewBuilder
    private func projectRow(_ project: ProjectSummary) -> some View {
        Label {
            Text(project.projectID).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: project.latestPassed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(project.latestPassed ? Color.green : Color.red)
        }
        .tag(SidebarItem.project(project.projectID))
    }

    /// A sidebar row's context-menu actions.
    @ViewBuilder
    private func rowMenu(_ projectID: String) -> some View {
        Button("Show Detail") { sidebar = .project(projectID) }
        Button("Back to Overview") { sidebar = .overview }
    }

    /// The groups whose members exist, name-sorted, each with its member summaries.
    private var groupedSections: [(id: String, members: [ProjectSummary])] {
        let byID = Dictionary(projects.map { ($0.projectID, $0) }, uniquingKeysWith: { first, _ in first })
        return groups.sorted { $0.key < $1.key }.compactMap { groupID, memberIDs in
            let members = memberIDs.compactMap { byID[$0] }.sorted { $0.projectID < $1.projectID }
            return members.isEmpty ? nil : (groupID, members)
        }
    }

    /// Projects that belong to no group, name-sorted.
    private var ungroupedProjects: [ProjectSummary] {
        let grouped = Set(groupedSections.flatMap { $0.members.map(\.projectID) })
        return projects.filter { !grouped.contains($0.projectID) }
    }

    /// The detail pane: a selected project's drill-down, or the overview.
    @ViewBuilder
    private var detailPane: some View {
        if case let .project(id) = sidebar, let project = projects.first(where: { $0.projectID == id }) {
            ProjectDetailView(project: project, pulse: pulse,
                              trends: trends[id] ?? [], inbox: inbox[id] ?? [])
        } else {
            overview
        }
    }

    /// The portfolio overview: header, projects table, and analytical sections.
    @ViewBuilder
    private var overview: some View {
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
                                      health: health, groups: groups,
                                      onSelectProject: { sidebar = .project($0) })
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
    }
}
#endif
