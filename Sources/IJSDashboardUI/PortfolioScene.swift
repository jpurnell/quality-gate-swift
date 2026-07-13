// PortfolioScene.swift
// IJSDashboardUI
//
// The portfolio screen as a SwiftGUIKit scene: a pure `Data -> Node` function.
// It carries every layout and content decision for the portfolio overview and is
// surface-agnostic — the same Node renders to native SwiftUI (SwiftUIRenderer)
// and, later, back to the terminal (CellRenderer). Because it's a pure value
// function, it is unit-tested by Node equality with no running view.

import SwiftGUIKit
import SwiftCLIKit
import IJSDashboardCore
import CorpusKit

/// Builds the IJS portfolio overview scene from the shared `IJSDashboardCore`
/// view models.
public enum PortfolioScene {

    /// The interaction id of the projects table (drill-down is wired later).
    public static let projectsTableID = "portfolio.projects"

    /// Builds the portfolio overview: a titled block containing a one-line
    /// summary, a portfolio pass-rate gauge, and a sortable projects table.
    /// - Parameters:
    ///   - portfolio: The cross-project rollup.
    ///   - projects: The per-project summaries (rendered as table rows).
    ///   - pulse: The latest institutional pulse, if available. Unlocks the header
    ///     line and the corpus-trend, violation-cluster, and narrative sections.
    /// - Returns: A ``Node`` scene tree.
    public static func scene(
        portfolio: PortfolioSummary,
        projects: [ProjectSummary],
        pulse: InstitutionalPulse? = nil,
        includeNarrative: Bool = true
    ) -> Node {
        let passRatio = portfolio.totalProjects > 0
            ? Double(portfolio.passingProjects) / Double(portfolio.totalProjects)
            : 0

        let summaryLine =
            "\(portfolio.totalProjects) projects · \(portfolio.passingProjects) passing · \(portfolio.failingProjects) failing"

        var children: [Node] = [Paragraph(text: summaryLine).node(color: .secondaryLabel)]
        if let pulse {
            children.append(pulseHeaderLine(pulse))
        }
        children.append(Gauge(ratio: passRatio, label: "\(percent(passRatio)) passing").node())
        children.append(projectsTable(projects))
        if let worst = worstCheckersSection(portfolio.worstCheckers) {
            children.append(worst)
        }
        if let pulse {
            let trend = pulse.statistics.corpusSnapshots.map(snapshotPassRate)
            if let trendSection = corpusTrendSection(passRates: trend) { children.append(trendSection) }
            if let clusters = violationClustersSection(clusterCells(pulse.violationClusters)) { children.append(clusters) }
            // The native surface renders the narrative as real Markdown (headers,
            // rules, inline styling) via NarrativeMarkdownView, so it is excluded
            // here; the plain-text `narrativeSection` remains for the portable path.
            if includeNarrative, let narrativeSection = narrativeSection(pulse.narrative) {
                children.append(narrativeSection)
            }
        }

        return Block(title: "IJS Portfolio Dashboard").node(child: .vstack(children))
    }

    /// The one-line portfolio summary (projects / passing / failing).
    static func summaryLine(_ portfolio: PortfolioSummary) -> String {
        "\(portfolio.totalProjects) projects · \(portfolio.passingProjects) passing · \(portfolio.failingProjects) failing"
    }

    /// The header portion: summary line, optional pulse line, and the pass-rate
    /// gauge — everything above the projects table. Used when the native surface
    /// renders the table itself (as a sortable `Table`).
    public static func headerScene(portfolio: PortfolioSummary, pulse: InstitutionalPulse? = nil) -> Node {
        let passRatio = portfolio.totalProjects > 0
            ? Double(portfolio.passingProjects) / Double(portfolio.totalProjects)
            : 0
        var children: [Node] = [Paragraph(text: summaryLine(portfolio)).node(color: .secondaryLabel)]
        if let pulse { children.append(pulseHeaderLine(pulse)) }
        children.append(Gauge(ratio: passRatio, label: "\(percent(passRatio)) passing").node())
        return .vstack(children)
    }

    /// The analytical sections between the projects table and the violation-cluster
    /// table: worst checkers and the corpus trend. (Violation clusters render as a
    /// native sortable table, and the narrative as native Markdown.)
    public static func sectionsScene(portfolio: PortfolioSummary, pulse: InstitutionalPulse? = nil) -> Node {
        var children: [Node] = []
        if let worst = worstCheckersSection(portfolio.worstCheckers) { children.append(worst) }
        if let pulse {
            let trend = pulse.statistics.corpusSnapshots.map(snapshotPassRate)
            if let trendSection = corpusTrendSection(passRates: trend) { children.append(trendSection) }
        }
        return .vstack(children.isEmpty ? [.spacer] : children)
    }

    // MARK: - Pulse-derived sections

    /// The pulse header line: label · runs · pass% · overrides · consistency.
    static func pulseHeaderLine(_ pulse: InstitutionalPulse) -> Node {
        let stats = pulse.statistics
        return pulseHeaderText(
            label: pulse.label ?? pulse.weekLabel,
            runs: stats.totalGateRuns,
            passRate: stats.passRate,          // already a 0–100 percentage
            overrides: stats.totalOverrides,
            consistency: stats.meanConsistencyScore
        )
    }

    static func pulseHeaderText(label: String, runs: Int, passRate: Double, overrides: Int, consistency: Double?) -> Node {
        let cons = consistency.map(twoDecimal) ?? "—"
        let text = "Pulse \(label) · \(runs) runs · \(oneDecimal(passRate))% pass · \(overrides) overrides · Consistency \(cons)"
        return Paragraph(text: text).node(color: .secondaryLabel)
    }

    /// The corpus pass-rate trend: a heading + sparkline. Nil when no history.
    static func corpusTrendSection(passRates: [Double]) -> Node? {
        guard !passRates.isEmpty else { return nil }
        return .vstack([
            Paragraph(text: "Corpus Trend (\(passRates.count)d)").node(color: .secondaryLabel),
            Sparkline(data: passRates).node(),
        ])
    }

    /// The top violation clusters: a heading + table. Nil when none.
    static func violationClustersSection(_ cells: [[String]]) -> Node? {
        guard !cells.isEmpty else { return nil }
        let widths: [Layout.Constraint] = [.min(28), .fixed(12), .fixed(12), .fixed(10)]
        return .vstack([
            Paragraph(text: "Violation Clusters").node(color: .secondaryLabel),
            .table(headers: ["Rule", "Last Wk", "This Wk", "Current"], widths: widths, cells: cells,
                   selectedRow: nil, scrollOffset: 0, sort: nil,
                   headerColor: .label, rowColor: .label, id: "portfolio.clusters"),
        ])
    }

    /// The institutional narrative: a heading + wrapped paragraph. Nil when absent.
    static func narrativeSection(_ narrative: String?) -> Node? {
        guard let narrative, !narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .vstack([
            Paragraph(text: "Narrative").node(color: .secondaryLabel),
            Paragraph(text: narrative).node(color: .label),
        ])
    }

    // MARK: - Pulse extraction helpers

    /// A daily snapshot's pass rate (0…1), division-guarded.
    static func snapshotPassRate(_ snapshot: DailySnapshot) -> Double {
        snapshot.gateRuns > 0 ? Double(snapshot.passedRuns) / Double(snapshot.gateRuns) : 0
    }

    /// The top-5 violation clusters projected into table rows
    /// (Rule · Last Wk · This Wk · Current), each count as "<occurrences>x/<projects>p".
    static func clusterCells(_ clusters: [ViolationCluster]) -> [[String]] {
        clusters.prefix(5).map { cluster in
            let lastWeek = cluster.priorOccurrenceCount.map { "\($0)x/\(cluster.priorProjectCount ?? 0)p" } ?? "?"
            let thisWeek = "\(cluster.occurrenceCount)x/\(cluster.affectedProjectCount)p"
            let current = cluster.currentOccurrenceCount.map { "\($0)x/\(cluster.currentProjectCount ?? 0)p" } ?? "N/A"
            return [cluster.ruleId, lastWeek, thisWeek, current]
        }
    }

    /// Rounds to one decimal place (e.g. 10.5) without C-style formatting.
    static func oneDecimal(_ value: Double) -> String {
        "\((value * 10).rounded() / 10)"
    }

    /// Rounds to two decimal places (e.g. 0.97) without C-style formatting.
    static func twoDecimal(_ value: Double) -> String {
        "\((value * 100).rounded() / 100)"
    }

    /// The "Worst Checkers" section: a heading over the (up to) five lowest-passing
    /// checkers across the portfolio. Returns `nil` when there are none.
    static func worstCheckersSection(_ checkers: [String]) -> Node? {
        let top = Array(checkers.prefix(5))
        guard !top.isEmpty else { return nil }
        var lines: [Node] = [Paragraph(text: "Worst Checkers").node(color: .secondaryLabel)]
        for checker in top {
            lines.append(Paragraph(text: "  • \(checker)").node(color: .label))
        }
        return .vstack(lines)
    }

    /// The projects table: Project · Status · Pass Rate · Runs, one row per project.
    static func projectsTable(_ projects: [ProjectSummary]) -> Node {
        let headers = ["Project", "Status", "Pass Rate", "Runs"]
        let widths: [Layout.Constraint] = [.min(20), .fixed(8), .fixed(10), .fixed(6)]
        let cells: [[String]] = projects.map { p in
            [
                p.projectID,
                p.latestPassed ? "pass" : "fail",
                percent(p.passRate),
                "\(p.runCount)",
            ]
        }
        return .table(
            headers: headers,
            widths: widths,
            cells: cells,
            selectedRow: nil,
            scrollOffset: 0,
            sort: nil,
            headerColor: .label,
            rowColor: .label,
            id: projectsTableID
        )
    }

    /// Formats a 0...1 ratio as an integer percentage string.
    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }
}
