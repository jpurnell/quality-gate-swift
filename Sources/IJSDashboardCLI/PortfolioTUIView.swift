import Foundation
import IJSDashboardCore
import SwiftCLIKit

/// Renders the portfolio overview as a box-drawn terminal frame.
public enum PortfolioTUIView: Sendable {

    /// Produces a formatted string for the portfolio view with project rows, gauges, and selection highlight.
    public static func render(
        portfolio: PortfolioSummary,
        projects: [ProjectSummary],
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
                + "  Status   Pass Rate        Runs"
            buf.appendLine(boxRow(header, width: width))
            buf.appendLine(box.midBorder(width: width))

            let sorted = projects.sorted { $0.projectID < $1.projectID }
            for (idx, project) in sorted.enumerated() {
                let isSelected = idx == state.selectedIndex
                let status = project.latestPassed ? "\u{2713}" : "\u{2717}"
                let pct = formatPercent(project.passRate)
                let name = String(project.projectID.prefix(nameWidth))
                    .padding(toLength: nameWidth, withPad: " ", startingAt: 0)

                let gauge = InlineGauge.render(
                    current: Int((project.passRate * 100).rounded()),
                    total: 100,
                    width: 8,
                    filledColor: project.latestPassed ? .ansi8(.green) : .ansi8(.red)
                )

                let row = "  \(name)  \(status)      \(gauge) \(pct.padding(toLength: 5, withPad: " ", startingAt: 0))  \(project.runCount)"

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

    private static func formatPercent(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return "\(pct)%"
    }
}
