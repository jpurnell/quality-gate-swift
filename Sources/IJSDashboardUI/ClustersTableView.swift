// ClustersTableView.swift
// IJSDashboardUI
//
// The violation clusters as a native SwiftUI `Table`. Each period's occurrence
// count is its own clean, right-aligned, numeric-sortable column (not a tangled
// "<n>x/<p>p" string), with the affected-project count broken out separately —
// so sorting by This Wk means what it looks like it means.

#if canImport(SwiftUI)
import SwiftUI
import CorpusKit

struct ClustersTableView: View {

    /// A cluster row: clean integers per period (for sorting and display), with a
    /// display string for periods that may be absent ("—").
    struct Row: Identifiable {
        let id: String        // ruleId
        let rule: String
        let thisWeek: Int     // occurrences this week
        let projects: Int     // projects affected this week
        let lastWeekSort: Int // priorOccurrenceCount ?? -1 (so "—" sorts to the bottom)
        let lastWeekText: String
        let currentSort: Int  // currentOccurrenceCount ?? -1
        let currentText: String
    }

    let clusters: [ViolationCluster]

    // Worst-first by default: most occurrences this week at the top.
    @State private var sortOrder: [KeyPathComparator<Row>] = [
        KeyPathComparator(\Row.thisWeek, order: .reverse)
    ]

    private var rows: [Row] {
        clusters.map { cluster in
            Row(
                id: cluster.ruleId,
                rule: cluster.ruleId,
                thisWeek: cluster.occurrenceCount,
                projects: cluster.affectedProjectCount,
                lastWeekSort: cluster.priorOccurrenceCount ?? -1,
                lastWeekText: cluster.priorOccurrenceCount?.formatted() ?? "—",
                currentSort: cluster.currentOccurrenceCount ?? -1,
                currentText: cluster.currentOccurrenceCount?.formatted() ?? "—"
            )
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Rule", value: \.rule) {
                Text($0.rule).lineLimit(1).truncationMode(.middle)
            }
            TableColumn("This Wk", value: \.thisWeek) {
                Text($0.thisWeek.formatted()).monospacedDigit()
            }
            TableColumn("Proj", value: \.projects) {
                Text($0.projects.formatted()).monospacedDigit()
            }
            TableColumn("Last Wk", value: \.lastWeekSort) {
                Text($0.lastWeekText).monospacedDigit()
            }
            TableColumn("Current", value: \.currentSort) {
                Text($0.currentText).monospacedDigit()
            }
        }
    }
}
#endif
