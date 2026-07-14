// AnalyticsTables.swift
// IJSDashboardUI
//
// Native grids and tables for the pulse-derived analytical sections: Tiers and
// Trajectory counts as one-row grids (categories as headers, counts beneath),
// Top Movers / Groups / Worst Checkers as sortable tables. Data is computed by
// the pure PulseAnalytics helpers.

#if canImport(SwiftUI)
import SwiftUI
import CorpusKit
import IJSDashboardCore

/// A one-row grid: category headers with a count beneath each.
private struct CountsGrid: View {
    let title: String
    let columns: [(label: String, count: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
                GridRow {
                    ForEach(columns.indices, id: \.self) { i in
                        Text(columns[i].label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    ForEach(columns.indices, id: \.self) { i in
                        Text("\(columns[i].count)").font(.title3).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// Tiers as a one-row grid (active · baseline · … with counts).
struct TierCountsView: View {
    let tiers: [ProjectTier]
    var body: some View {
        let counts = PulseAnalytics.tierCounts(tiers)
        if !counts.isEmpty {
            CountsGrid(title: "Tiers", columns: counts.map { ($0.tier.rawValue, $0.count) })
        }
    }
}

/// Trajectory direction counts as a one-row grid (Improving · Stable · Declining).
struct TrajectoryCountsView: View {
    let directions: [TrajectoryDirection]
    var body: some View {
        if !directions.isEmpty {
            let counts = PulseAnalytics.directionCounts(directions)
            CountsGrid(title: "Trajectories", columns: counts.map { ($0.direction.rawValue, $0.count) })
        }
    }
}

/// The steepest movers as a sortable table (Project · Trajectory).
struct TopMoversTable: View {
    let movers: [(id: String, slope: Double)]

    struct Row: Identifiable {
        let id: String
        let project: String
        let trajectory: String
        let magnitude: Double
    }

    @State private var sortOrder = [KeyPathComparator(\Row.magnitude, order: .reverse)]

    private var rows: [Row] {
        PulseAnalytics.topMovers(movers)
            .map { Row(id: $0.id, project: $0.id, trajectory: $0.trajectory, magnitude: $0.magnitude) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Top Movers").font(.headline)
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Project", value: \.project) {
                        Text($0.project).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Trajectory", value: \.magnitude) {
                        Text($0.trajectory).monospacedDigit()
                    }
                }
                .resizableHeight(initial: 150)
            }
        }
    }
}

/// Groups as a sortable table (Group · Pass Rate · Runs).
struct GroupsTable: View {
    let groups: [(name: String, passRate: Double, runs: Int)]

    struct Row: Identifiable {
        let id: String
        let group: String
        let passRate: Double
        let runs: Int
    }

    @State private var sortOrder = [KeyPathComparator(\Row.group)]

    private var rows: [Row] {
        groups
            .map { Row(id: $0.name, group: $0.name, passRate: $0.passRate, runs: $0.runs) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Groups").font(.headline)
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Group", value: \.group) {
                        Text($0.group).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Pass Rate", value: \.passRate) {
                        Text("\(Int($0.passRate.rounded()))%").monospacedDigit()
                    }
                    TableColumn("Runs", value: \.runs) {
                        Text("\($0.runs)").monospacedDigit()
                    }
                }
                .resizableHeight(initial: 200)
            }
        }
    }
}

/// Worst checkers as a sortable table (Checker · Pass Rate · Failures).
struct WorstCheckersTable: View {
    let stats: [(checker: String, passRate: Double, failures: Int)]

    struct Row: Identifiable {
        let id: String
        let checker: String
        let passRate: Double
        let failures: Int
    }

    // Worst-first: lowest aggregate pass rate at the top.
    @State private var sortOrder = [KeyPathComparator(\Row.passRate, order: .forward)]

    private var rows: [Row] {
        stats
            .map { Row(id: $0.checker, checker: $0.checker, passRate: $0.passRate, failures: $0.failures) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Worst Checkers").font(.headline)
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Checker", value: \.checker) {
                        Text($0.checker).lineLimit(1).truncationMode(.middle)
                    }
                    TableColumn("Pass Rate", value: \.passRate) {
                        Text("\(Int($0.passRate.rounded()))%").monospacedDigit()
                    }
                    TableColumn("Failures", value: \.failures) {
                        Text("\($0.failures)").monospacedDigit()
                    }
                }
                .resizableHeight(initial: 200)
            }
        }
    }
}
#endif
