// ProjectDetailView.swift
// IJSDashboardUI
//
// The project drill-down: a tabbed detail screen (Summary / Checkers / Inbox)
// reached by selecting a project in the portfolio table. It renders from data
// already loaded into the dashboard — the project summary, the latest pulse, the
// health series, and the advisory inbox — so no extra corpus read is needed.
// This mirrors the terminal ProjectDetailTUIView, natively.

#if canImport(SwiftUI)
import SwiftUI
import IJSDashboardCore
import CorpusKit
#if canImport(AppKit)
import AppKit
#endif

/// A tabbed detail view for a single project.
public struct ProjectDetailView: View {

    /// The tabs, matching the terminal detail view.
    private enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case checkers = "Checkers"
        case inbox = "Inbox"
        var id: String { rawValue }
    }

    private let project: ProjectSummary
    private let pulse: InstitutionalPulse?
    private let trends: [TrendPoint]
    private let inbox: [InboxFinding]

    @State private var tab: Tab = .summary

    /// Creates the detail view for one project.
    /// - Parameters:
    ///   - project: The project's aggregated summary.
    ///   - pulse: The latest institutional pulse, for tier/score/trajectory.
    ///   - trends: The project's daily pass-rate trend, for the trend chart.
    ///   - inbox: Advisory findings from the project's latest run.
    public init(project: ProjectSummary, pulse: InstitutionalPulse?,
                trends: [TrendPoint] = [], inbox: [InboxFinding] = []) {
        self.project = project
        self.pulse = pulse
        self.trends = trends
        self.inbox = inbox
    }

    /// The detail view body.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            .frame(maxWidth: 420)

            Divider().padding(.top, 12)

            switch tab {
            case .summary: ScrollView { summary.padding() }
            case .checkers: checkers
            case .inbox: inboxTable
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle(project.projectID)
    }

    // MARK: Summary

    private var trajectory: ProjectTrajectory? {
        pulse?.projectTrajectories?.first { $0.projectID == project.projectID }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusHeader
            metricsSection
            statusSection
            if let baseline = project.latestBaseline { baselineSection(baseline) }
            if let orientation = project.orientation { orientationSection(orientation) }
            trendSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var statusBadgeText: String {
        switch project.gateStatus {
        case .failing: return "FAILING"
        case .passingPartial: return "PASSING *"
        case .passingConfirmed: return "PASSING"
        }
    }

    private var statusBadgeColor: Color {
        switch project.gateStatus {
        case .failing: return .red
        case .passingPartial: return .yellow
        case .passingConfirmed: return .green
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(project.projectID).font(.title2.bold())
                Text(statusBadgeText)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(statusBadgeColor.opacity(0.2))
                    .foregroundStyle(statusBadgeColor)
                    .clipShape(Capsule())
                    .help(project.gateStatus == .passingPartial
                          ? "Every checker passes, but no full gate run has confirmed it yet (assembled from partial --check runs)."
                          : "")
            }
            if let census = project.writerCensus, census.tripped {
                Label("Multi-writer (\(census.persons.joined(separator: ", "))) — Phase 3 controls required",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pass Rate").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                Gauge(value: min(max(project.passRate, 0), 1)) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(project.latestPassed ? Color.green : Color.red)
                    .frame(maxWidth: 260)
                Text("\(Int((project.passRate * 100).rounded()))%").monospacedDigit()
            }
            metricRow("Runs", runsText)
            metricRow("Overrides", "\(project.totalOverrides)")
            if let worst = project.worstChecker { metricRow("Worst Checker", worst) }
        }
    }

    private var runsText: String {
        project.partialRunCount > 0
            ? "\(project.runCount) full (+\(project.partialRunCount) partial)"
            : "\(project.runCount)"
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status").font(.headline)
            if let tier = pulse?.projectTiers?[project.projectID] {
                metricRow("Tier", ProjectDetailFormat.tierLabel(tier))
            }
            metricRow("Quality Score",
                      ProjectDetailFormat.scoreText(pulse?.statistics.weightedScores?[project.projectID]))
            if let traj = trajectory {
                metricRow("Trajectory", trajectoryText(traj))
            }
        }
    }

    private func trajectoryText(_ traj: ProjectTrajectory) -> String {
        let base = "\(ProjectDetailFormat.slopeArrow(traj.slope)) \(ProjectDetailFormat.trajectoryLabel(traj.direction)) "
            + "(slope \(ProjectDetailFormat.fixed(traj.slope, places: 3)), R² \(ProjectDetailFormat.fixed(traj.rSquared, places: 2)), n=\(traj.sampleSize))"
        return traj.inflectionDetected ? base + " · inflection" : base
    }

    @ViewBuilder
    private func baselineSection(_ baseline: BaselineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Baseline").font(.headline)
            metricRow("Debts", "\(baseline.baselined)")
            if baseline.expired > 0 {
                metricRow("Expired", "\(baseline.expired)")
            }
            if baseline.newFindings > 0 {
                metricRow("New Findings", "\(baseline.newFindings)")
            }
            let trail = ProjectDetailFormat.burnDownTrail(project.baselineBurnDown)
            if !trail.isEmpty { metricRow("Burn-down", trail) }
        }
    }

    @ViewBuilder
    private func orientationSection(_ card: ModuleOrientationCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Orientation").font(.headline)
            if let what = card.whatItDoes { metricRow("What it does", what) }
            metricRow("Role", card.role)
            if !card.dependsOn.isEmpty { metricRow("Built from", elided(card.dependsOn)) }
            if !card.reliedOnBy.isEmpty { metricRow("Relied on by", elided(card.reliedOnBy)) }
            if let why = card.why { metricRow("Why", why) }
        }
    }

    private func elided(_ items: [String], limit: Int = 6) -> String {
        guard items.count > limit else { return items.joined(separator: ", ") }
        return items.prefix(limit).joined(separator: ", ") + " (+\(items.count - limit) more)"
    }

    @ViewBuilder
    private var trendSection: some View {
        if trends.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pass Rate Trend").font(.headline)
                ProjectTrendChartView(points: trends)
                Text("Direction: \(ProjectDetailFormat.trendDirection(trends.map(\.value))) (\(trends.count) days)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Checkers

    @ViewBuilder
    private var checkers: some View {
        let rows = ProjectDetailFormat.checkerRows(passRates: project.checkerPassRates,
                                                   latestPassed: project.latestCheckerPassed)
        if rows.isEmpty {
            emptyState("No checker history for this project.")
        } else {
            CheckersDetailTable(rows: rows)
        }
    }

    // MARK: Inbox

    @ViewBuilder
    private var inboxTable: some View {
        if inbox.isEmpty {
            emptyState("Inbox zero — no advisory findings in the latest run.")
        } else {
            InboxTable(findings: inbox)
        }
    }

    // MARK: Shared bits

    @ViewBuilder
    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The Checkers tab as a native sortable table.
private struct CheckersDetailTable: View {
    let rows: [ProjectDetailFormat.CheckerRow]
    @State private var sortOrder = [KeyPathComparator(\ProjectDetailFormat.CheckerRow.passRate)]

    var body: some View {
        Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Checker", value: \.name) { Text($0.name).lineLimit(1).truncationMode(.middle) }
            TableColumn("Latest") { row in
                Text(row.latestPassed ? "✓" : "✗")
                    .foregroundStyle(row.latestPassed ? Color.green : Color.red)
            }
            TableColumn("Pass Rate", value: \.passRate) { row in
                HStack(spacing: 8) {
                    Gauge(value: min(max(row.passRate, 0), 1)) { EmptyView() }
                        .gaugeStyle(.linearCapacity)
                        .tint(row.passRate >= 0.9 ? Color.green : (row.passRate >= 0.6 ? Color.orange : Color.red))
                        .frame(maxWidth: 120)
                    Text("\(row.passPercent)%").monospacedDigit()
                }
            }
        }
    }
}

/// The Inbox tab as a native sortable table of advisory findings.
private struct InboxTable: View {
    let findings: [InboxFinding]

    /// A row: a rule group (findings of one rule, disclosed beneath it) or one
    /// finding. Group rows leave the finding-specific columns blank.
    struct Node: Identifiable {
        let id: String
        let rule: String
        let file: String
        let line: Int
        let lineText: String
        let message: String
        let acknowledgeable: Bool
        let children: [Node]?
        var isGroup: Bool { children != nil }
    }

    @State private var selection = Set<Node.ID>()
    @State private var sortOrder = [KeyPathComparator(\Node.rule)]

    var body: some View {
        Table(of: Node.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Rule", value: \.rule) { node in
                Text(node.rule).fontWeight(node.isGroup ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle)
            }
            TableColumn("File", value: \.file) { Text($0.file).lineLimit(1).truncationMode(.middle) }
            TableColumn("Line", value: \.line) { Text($0.lineText).monospacedDigit() }
            TableColumn("Message", value: \.message) { Text($0.message).lineLimit(2) }
            TableColumn("Ack") { node in
                if node.isGroup {
                    Color.clear.frame(width: 1, height: 1)
                } else {
                    Text(node.acknowledgeable ? "✓" : "—")
                        .foregroundStyle(node.acknowledgeable ? Color.green : Color.secondary)
                }
            }
        } rows: {
            ForEach(topRows) { node in
                if let children = node.children {
                    DisclosureTableRow(node) { ForEach(children) { TableRow($0) } }
                } else {
                    TableRow(node)
                }
            }
        }
        // Copy the right-clicked row, or the whole selection when it's part of it
        // — so findings copy individually and in bulk. ⌘C copies the selection.
        .contextMenu(forSelectionType: Node.ID.self) { ids in
            Button("Copy") { copy(ids) }
        }
        .copyable([findingLines(for: selection).joined(separator: "\n")])
    }

    /// Writes the selected findings to the pasteboard as tab-separated lines
    /// (rule · file:line · message) — one per finding, expanding any selected group.
    private func copy(_ ids: Set<Node.ID>) {
        let text = findingLines(for: ids).joined(separator: "\n")
        guard !text.isEmpty else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// The tab-separated text for each selected finding. A selected group id
    /// expands to all its members; leaf ids resolve to themselves. De-duplicated.
    private func findingLines(for ids: Set<Node.ID>) -> [String] {
        guard !ids.isEmpty else { return [] }
        var seen = Set<Node.ID>()
        var lines: [String] = []
        for group in topRows {
            let members = group.children ?? []
            let takeAll = ids.contains(group.id)
            for leaf in members where (takeAll || ids.contains(leaf.id)) && seen.insert(leaf.id).inserted {
                lines.append("\(leaf.rule)\t\(leaf.file):\(leaf.line)\t\(leaf.message)")
            }
        }
        return lines
    }

    /// Findings grouped by rule: each rule is a disclosure row (name + count)
    /// whose members are its findings, file/line-sorted. Sorted by the current order.
    private var topRows: [Node] {
        let grouped = Dictionary(grouping: findings, by: \.ruleID)
        let rows = grouped.sorted { $0.key < $1.key }.map { rule, items -> Node in
            let children = items
                .sorted { ($0.fileName, $0.lineNumber) < ($1.fileName, $1.lineNumber) }
                .map { finding in
                    Node(id: finding.id, rule: rule, file: finding.fileName,
                         line: finding.lineNumber, lineText: "\(finding.lineNumber)",
                         message: finding.message, acknowledgeable: finding.acknowledgeable,
                         children: nil)
                }
            return Node(id: "rule:\(rule)", rule: "\(rule) (\(children.count))",
                        file: "", line: 0, lineText: "", message: "",
                        acknowledgeable: false, children: children)
        }
        return rows.sorted(using: sortOrder)
    }
}
#endif
