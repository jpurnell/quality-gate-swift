// ClustersTableView.swift
// IJSDashboardUI
//
// The violation clusters as a native SwiftUI `Table`: sortable by occurrence
// counts, resizable columns. Like ProjectsTableView, this is a native-surface
// rendering — sorting by a numeric column while displaying a formatted string is
// something the cross-surface `.table` node can't express.

#if canImport(SwiftUI)
import SwiftUI
import CorpusKit

struct ClustersTableView: View {

    /// A cluster row: a numeric count per period (for sorting) plus its display
    /// string "<occurrences>x/<projects>p".
    struct Row: Identifiable {
        let id: String        // ruleId
        let rule: String
        let lastWeek: String
        let lastWeekCount: Int
        let thisWeek: String
        let thisWeekCount: Int
        let current: String
        let currentCount: Int
    }

    let clusters: [ViolationCluster]

    // Worst-first by default: most occurrences this week at the top.
    @State private var sortOrder: [KeyPathComparator<Row>] = [
        KeyPathComparator(\Row.thisWeekCount, order: .reverse)
    ]

    private var rows: [Row] {
        clusters.map { cluster in
            Row(
                id: cluster.ruleId,
                rule: cluster.ruleId,
                lastWeek: cluster.priorOccurrenceCount.map { "\($0)x/\(cluster.priorProjectCount ?? 0)p" } ?? "?",
                lastWeekCount: cluster.priorOccurrenceCount ?? -1,
                thisWeek: "\(cluster.occurrenceCount)x/\(cluster.affectedProjectCount)p",
                thisWeekCount: cluster.occurrenceCount,
                current: cluster.currentOccurrenceCount.map { "\($0)x/\(cluster.currentProjectCount ?? 0)p" } ?? "N/A",
                currentCount: cluster.currentOccurrenceCount ?? -1
            )
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Rule", value: \.rule) {
                Text($0.rule).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("Last Wk", value: \.lastWeekCount) { Text($0.lastWeek) }
            TableColumn("This Wk", value: \.thisWeekCount) { Text($0.thisWeek) }
            TableColumn("Current", value: \.currentCount) { Text($0.current) }
        }
    }
}
#endif
