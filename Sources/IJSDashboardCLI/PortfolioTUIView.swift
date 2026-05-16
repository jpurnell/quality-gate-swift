import Foundation
import IJSDashboardCore
import SwiftCLIKit

/// Renders the portfolio overview as a box-drawn terminal frame.
public enum PortfolioTUIView: Sendable {

    private static let timelineWidth = 10

    /// Produces a formatted string for the portfolio view with project rows, gauges, and selection highlight.
    public static func render(
        portfolio: PortfolioSummary,
        projects: [ProjectSummary],
        allRuns: [String: [TimestampedRun]],
        state: DashboardState,
        width: Int
    ) -> String {
        let box = BoxDrawing.unicode
        var buf = ScreenBuffer(width: width)

        buf.appendLine(box.topBorder(" IJS Portfolio Dashboard ", width: width))
        buf.appendLine(boxRow("", width: width))

        let statusLine = "  \(portfolio.totalProjects) projects | \(portfolio.passingProjects) passing | \(portfolio.failingProjects) failing"
        buf.appendLine(boxRow(statusLine, width: width))
        buf.appendLine(boxRow("", width: width))

        if !projects.isEmpty {
            let nameWidth = min(max(width - 40, 16), 30)
            let header = "  " + "Project".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                + "  Status  Health      Runs"
            buf.appendLine(boxRow(header, width: width))
            buf.appendLine(box.midBorder(width: width))

            let sorted = projects.sorted { $0.projectID < $1.projectID }
            for (idx, project) in sorted.enumerated() {
                let isSelected = idx == state.selectedIndex
                let status = project.latestPassed ? "\u{2713}" : "\u{2717}"
                let pct = formatPercent(project.passRate)
                let name = String(project.projectID.prefix(nameWidth))
                    .padding(toLength: nameWidth, withPad: " ", startingAt: 0)

                let runs = allRuns[project.projectID] ?? []
                let timeline = renderHealthTimeline(runs: runs)

                let row = "  \(name)  \(status)     \(timeline) \(pct.padding(toLength: 5, withPad: " ", startingAt: 0))  \(project.runCount)"

                if isSelected {
                    buf.appendLine(boxRow(ANSICodes.reverse + row + ANSICodes.reset, width: width))
                } else {
                    buf.appendLine(boxRow(row, width: width))
                }
            }
            buf.appendLine(boxRow("", width: width))
        }

        if !portfolio.worstCheckers.isEmpty {
            buf.appendLine(box.midBorder(width: width))
            buf.appendLine(boxRow("  Worst Checkers:", width: width))
            for checker in portfolio.worstCheckers.prefix(5) {
                buf.appendLine(boxRow("    - \(checker)", width: width))
            }
            buf.appendLine(boxRow("", width: width))
        }

        buf.appendLine(box.bottomBorder(width: width))

        let helpLine = ANSICodes.dim + "  \u{2191}\u{2193} Navigate  Enter Select  q Quit  (live reload every 30s)" + ANSICodes.reset
        buf.appendLine(helpLine)

        return buf.raw
    }

    private static func boxRow(_ content: String, width: Int) -> String {
        let box = BoxDrawing.unicode
        let visLen = ANSIStringMetrics.visibleLength(content)
        let innerWidth = width - 2
        let padding = max(0, innerWidth - visLen)
        return box.vertical + content
            + String(repeating: " ", count: padding)
            + box.vertical
    }

    private static func renderHealthTimeline(runs: [TimestampedRun]) -> String {
        let sortedRuns = runs.sorted { $0.metadata.timestamp < $1.metadata.timestamp }
        let recentRuns = Array(sortedRuns.suffix(timelineWidth))

        var cells = ""
        let padding = max(0, timelineWidth - recentRuns.count)
        if padding > 0 {
            cells += ANSICodes.dim + String(repeating: "\u{2500}", count: padding) + ANSICodes.reset
        }
        for run in recentRuns {
            let results = run.metadata.results
            guard !results.isEmpty else {
                cells += ANSICodes.dim + "\u{2591}" + ANSICodes.reset
                continue
            }
            let passingCount = results.filter { $0.status.isPassing }.count
            let rate = Double(passingCount) / Double(results.count)
            cells += healthColor(rate) + "\u{2588}" + ANSICodes.reset
        }
        return cells
    }

    private static func healthColor(_ rate: Double) -> String {
        let pct = Int((rate * 100).rounded())
        if pct >= 90 {
            return ANSICodes.fg(.green)
        } else if pct >= 75 {
            return ANSICodes.fg(.yellow)
        } else if pct >= 60 {
            return "\u{001B}[38;2;255;165;0m"
        } else {
            return ANSICodes.fg(.red)
        }
    }

    private static func formatPercent(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return "\(pct)%"
    }
}
