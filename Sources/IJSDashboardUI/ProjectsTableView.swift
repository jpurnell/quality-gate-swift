// ProjectsTableView.swift
// IJSDashboardUI
//
// The projects table as a native SwiftUI `Table`: resizable columns and
// click-to-sort headers. This is a native-surface rendering (not the shared
// SwiftGUIKit scene) — `Table` is strongly typed and stateful (sort order, column
// widths), which the cross-surface `.table` node can't express. The proposal's
// "path to B" trigger: a native interaction the scene can't do, invoked cheaply
// because IJSDashboardCore is the shared source of the data.

#if canImport(SwiftUI)
import SwiftUI
import IJSDashboardCore
import CorpusKit

struct ProjectsTableView: View {

    /// A table row projected from a `ProjectSummary`, with sortable columns.
    struct Row: Identifiable {
        let id: String
        let project: String
        let passed: Bool
        let passRate: Double
        let runCount: Int
        let anomaly: String        // "" when none
        let anomalyMagnitude: Double
        let anomalyGood: Bool
        var status: String { passed ? "pass" : "fail" }
        var passRatePercent: Int { Int((passRate * 100).rounded()) }
    }

    let projects: [ProjectSummary]
    var anomalies: [StatisticalAnomaly] = []

    @State private var sortOrder: [KeyPathComparator<Row>] = [KeyPathComparator(\Row.project)]

    private var rows: [Row] {
        let lookup = AnomalyFormat.lookup(anomalies)
        return projects
            .map { project in
                let cell = lookup[project.projectID]
                return Row(id: project.projectID, project: project.projectID, passed: project.latestPassed,
                           passRate: project.passRate, runCount: project.runCount,
                           anomaly: cell?.text ?? "", anomalyMagnitude: cell?.magnitude ?? 0,
                           anomalyGood: cell?.isGood ?? false)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Project", value: \.project) {
                // Middle truncation: prefix-sharing project families (e.g.
                // BioFeedbackKit-EdgeBLE vs -HRBLE) differ at the end, so the tail
                // must stay visible — matching the TUI dashboard.
                Text($0.project).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Status", value: \.status) { row in
                Text(row.status).foregroundStyle(row.passed ? Color.green : Color.red)
            }
            TableColumn("Pass Rate", value: \.passRate) { Text("\($0.passRatePercent)%") }
            TableColumn("Runs", value: \.runCount) { Text("\($0.runCount)") }
            TableColumn("Anomaly", value: \.anomalyMagnitude) { row in
                Text(row.anomaly).foregroundStyle(Self.anomalyColor(row))
            }
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
