// ProjectsTableView.swift
// IJSDashboardUI
//
// The projects table as a native SwiftUI `Table`: resizable columns, click-to-sort
// headers, per-project Health heatmap and Anomaly columns, and expandable group
// rows (a group aggregates its members; disclosure reveals them) — matching the
// terminal dashboard. This is a native-surface rendering; the cross-surface
// `.table` node can't express sorting, disclosure, or per-cell views.

#if canImport(SwiftUI)
import SwiftUI
import IJSDashboardCore
import CorpusKit

struct ProjectsTableView: View {

    /// A row — a project, or a group whose `members` disclose beneath it.
    struct Row: Identifiable {
        let id: String
        let name: String
        let gate: ProjectSummary.GateStatus
        let passRate: Double
        let runCount: Int
        let health: [Double]
        let healthRecent: Double
        let anomaly: String
        let anomalyMagnitude: Double
        let anomalyGood: Bool
        let members: [Row]?
        var status: String {
            switch gate {
            case .failing: return "fail"
            case .passingPartial: return "pass*"
            case .passingConfirmed: return "pass"
            }
        }
        var statusColor: Color {
            switch gate {
            case .failing: return .red
            case .passingPartial: return .yellow
            case .passingConfirmed: return .green
            }
        }
        var passRatePercent: Int { Int((passRate * 100).rounded()) }
        var isGroup: Bool { members != nil }
    }

    let projects: [ProjectSummary]
    var anomalies: [StatisticalAnomaly] = []
    var health: [String: [Double]] = [:]
    var groups: [String: [String]] = [:]
    /// Called with a project's ID when its row is selected (group rows are ignored).
    var onSelectProject: (String) -> Void = { _ in }

    @State private var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.name)]
    @State private var selection: Row.ID?

    var body: some View {
        Table(of: Row.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Project", value: \.name) { row in
                Text(row.name).lineLimit(1).truncationMode(.middle)
                    .fontWeight(row.isGroup ? .semibold : .regular)
            }
            TableColumn("Status", value: \.status) { row in
                Text(row.status).foregroundStyle(row.statusColor)
                    .help(row.gate == .passingPartial
                          ? "Every checker passes, but no full gate run has confirmed it yet (assembled from partial --check runs)."
                          : "")
            }
            TableColumn("Health", value: \.healthRecent) { row in
                if row.isGroup { Color.clear.frame(width: 1, height: 1) } else { healthBar(row.health) }
            }
            TableColumn("Pass Rate", value: \.passRate) { Text("\($0.passRatePercent)%").monospacedDigit() }
            TableColumn("Runs", value: \.runCount) { Text("\($0.runCount)").monospacedDigit() }
            TableColumn("Anomaly", value: \.anomalyMagnitude) { row in
                Text(row.anomaly).foregroundStyle(Self.anomalyColor(row))
            }
        } rows: {
            ForEach(topRows) { row in
                if let members = row.members {
                    DisclosureTableRow(row) {
                        ForEach(members) { TableRow($0) }
                    }
                } else {
                    TableRow(row)
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            // Navigate on project selection; ignore group rows, then clear so
            // re-selecting the same project drills in again.
            guard let id = newValue else { return }
            if !id.hasPrefix("group:") { onSelectProject(id) }
            selection = nil
        }
    }

    // MARK: Row building

    /// Top-level rows: each group (aggregated, with member children) followed by
    /// the ungrouped projects, sorted by the current sort order.
    private var topRows: [Row] {
        let lookup = AnomalyFormat.lookup(anomalies)
        let byID = Dictionary(projects.map { ($0.projectID, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped = Set<String>()
        var rows: [Row] = []

        for (groupID, memberIDs) in groups.sorted(by: { $0.key < $1.key }) {
            let members = memberIDs.compactMap { byID[$0] }
            guard !members.isEmpty else { continue }
            for member in members { grouped.insert(member.projectID) }

            let memberRows = members.map { projectRow($0, lookup: lookup) }.sorted { $0.name < $1.name }
            let count = members.count
            let passRate = count > 0 ? members.map(\.passRate).reduce(0, +) / Double(count) : 0
            rows.append(Row(
                id: "group:\(groupID)", name: "\(groupID) (\(count))",
                gate: ProjectSummary.GateStatus.aggregate(members.map(\.gateStatus)),
                passRate: passRate, runCount: members.map(\.runCount).reduce(0, +),
                health: [], healthRecent: passRate,
                anomaly: "", anomalyMagnitude: 0, anomalyGood: false,
                members: memberRows))
        }

        for project in projects where !grouped.contains(project.projectID) {
            rows.append(projectRow(project, lookup: lookup))
        }
        return rows.sorted(using: sortOrder)
    }

    private func projectRow(_ project: ProjectSummary, lookup: [String: AnomalyFormat.Cell]) -> Row {
        let cell = lookup[project.projectID]
        let series = health[project.projectID] ?? []
        return Row(
            id: project.projectID, name: project.projectID, gate: project.gateStatus,
            passRate: project.passRate, runCount: project.runCount,
            health: series, healthRecent: HealthTimeline.recentMean(series),
            anomaly: cell?.text ?? "", anomalyMagnitude: cell?.magnitude ?? 0,
            anomalyGood: cell?.isGood ?? false, members: nil)
    }

    // MARK: Cell rendering

    /// A compact heatmap of the recent runs' pass rates — one colored cell per run.
    @ViewBuilder
    private func healthBar(_ values: [Double]) -> some View {
        let recent = Array(values.suffix(12))
        HStack(spacing: 1) {
            ForEach(recent.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Self.levelColor(HealthTimeline.level(recent[i])))
                    .frame(width: 5, height: 12)
            }
        }
    }

    private static func levelColor(_ level: HealthTimeline.Level) -> Color {
        switch level {
        case .good: .green
        case .ok: .yellow
        case .warn: .orange
        case .bad: .red
        }
    }

    /// Green when the anomaly is an improvement; otherwise redder as |z| grows.
    private static func anomalyColor(_ row: Row) -> Color {
        guard !row.anomaly.isEmpty else { return .secondary }
        if row.anomalyGood { return .green }
        if row.anomalyMagnitude > 2.576 { return .red }
        if row.anomalyMagnitude >= 1.96 { return .orange }
        return .secondary
    }
}
#endif
