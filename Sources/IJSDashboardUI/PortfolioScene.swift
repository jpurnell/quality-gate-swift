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
    /// - Returns: A ``Node`` scene tree.
    public static func scene(portfolio: PortfolioSummary, projects: [ProjectSummary]) -> Node {
        let passRatio = portfolio.totalProjects > 0
            ? Double(portfolio.passingProjects) / Double(portfolio.totalProjects)
            : 0

        let summaryLine =
            "\(portfolio.totalProjects) projects · \(portfolio.passingProjects) passing · \(portfolio.failingProjects) failing"

        var children: [Node] = [
            Paragraph(text: summaryLine).node(color: .secondaryLabel),
            Gauge(ratio: passRatio, label: "\(percent(passRatio)) passing").node(),
            projectsTable(projects),
        ]
        if let worst = worstCheckersSection(portfolio.worstCheckers) {
            children.append(worst)
        }

        return Block(title: "IJS Portfolio Dashboard").node(child: .vstack(children))
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
