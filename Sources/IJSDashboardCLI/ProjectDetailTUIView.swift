import Foundation
import IJSDashboardCore
import SwiftCLIKit

/// Renders the project detail view with tabbed content as a box-drawn terminal frame.
public enum ProjectDetailTUIView: Sendable {

    /// Produces a formatted string for the project detail view with the active tab's content.
    public static func render(
        project: ProjectSummary,
        trends: [TrendPoint],
        state: DashboardState,
        width: Int
    ) -> String {
        let box = BoxDrawing.unicode
        var buf = ScreenBuffer(width: width)

        let titleHeader = " \(project.projectID) "
        buf.appendLine(box.topBorder(titleHeader, width: width))
        buf.appendLine(boxRow("", width: width))

        renderTabBar(into: &buf, selectedTab: state.selectedTab, width: width)
        buf.appendLine(box.midBorder(width: width))

        switch state.selectedTab {
        case .overview:
            renderOverview(into: &buf, project: project, width: width)
        case .checkers:
            renderCheckers(into: &buf, project: project, width: width)
        case .trends:
            renderTrends(into: &buf, trends: trends, width: width)
        }

        buf.appendLine(box.bottomBorder(width: width))

        let helpLine = ANSICodes.dim + "  Tab/Shift-Tab Switch tabs  Esc Back  q Quit" + ANSICodes.reset
        buf.appendLine(helpLine)

        return buf.raw
    }

    // MARK: - Tab Bar

    private static func renderTabBar(into buf: inout ScreenBuffer, selectedTab: DetailTab, width: Int) {
        let tabs: [(DetailTab, String)] = [
            (.overview, "Overview"),
            (.checkers, "Checkers"),
            (.trends, "Trends"),
        ]

        var tabLine = "  "
        for (tab, label) in tabs {
            if tab == selectedTab {
                tabLine += ANSICodes.bold + ANSICodes.underline + label + ANSICodes.reset + "  "
            } else {
                tabLine += ANSICodes.dim + label + ANSICodes.reset + "  "
            }
        }
        buf.appendLine(boxRow(tabLine, width: width))
    }

    // MARK: - Overview Tab

    private static func renderOverview(into buf: inout ScreenBuffer, project: ProjectSummary, width: Int) {
        let status = project.latestPassed ? "PASSING" : "FAILING"
        let statusColor: ANSIColor = project.latestPassed ? .green : .red
        let statusStyled = ANSICodes.bold + ANSICodes.fg(statusColor) + status + ANSICodes.reset

        buf.appendLine(boxRow("", width: width))
        buf.appendLine(boxRow("  Status:      " + statusStyled, width: width))

        let pctStr = formatPercent(project.passRate)
        let gauge = InlineGauge.renderWithLabel(
            current: Int((project.passRate * 100).rounded()),
            total: 100,
            width: 20,
            filledColor: project.latestPassed ? .ansi8(.green) : .ansi8(.red)
        )
        buf.appendLine(boxRow("  Pass Rate:   \(gauge)  \(pctStr)", width: width))
        buf.appendLine(boxRow("  Runs:        \(project.runCount)", width: width))
        buf.appendLine(boxRow("  Overrides:   \(project.totalOverrides)", width: width))

        if let worst = project.worstChecker {
            buf.appendLine(boxRow("  Worst:       \(worst)", width: width))
        }
        buf.appendLine(boxRow("", width: width))
    }

    // MARK: - Checkers Tab

    private static func renderCheckers(into buf: inout ScreenBuffer, project: ProjectSummary, width: Int) {
        buf.appendLine(boxRow("", width: width))
        if project.checkerPassRates.isEmpty {
            buf.appendLine(boxRow("  No checker data available.", width: width))
        } else {
            let sorted = project.checkerPassRates.sorted { $0.value < $1.value }
            for (checker, rate) in sorted {
                let passingNow = project.latestCheckerPassed[checker] ?? false
                let indicator = passingNow ? "\u{2713}" : "\u{2717}"
                let indicatorColor = passingNow ? ANSICodes.fg(.green) : ANSICodes.fg(.red)
                let barColor = rateColor(rate)
                let pctStr = formatPercent(rate)
                let gauge = InlineGauge.render(
                    current: Int((rate * 100).rounded()),
                    total: 100,
                    width: 15,
                    filledColor: barColor
                )
                let name = checker.padding(toLength: 22, withPad: " ", startingAt: 0)
                buf.appendLine(boxRow("  \(indicatorColor)\(indicator)\(ANSICodes.reset) \(name) \(gauge) \(pctStr)", width: width))
            }
        }
        buf.appendLine(boxRow("", width: width))
    }

    private static func rateColor(_ rate: Double) -> Color {
        let pct = Int((rate * 100).rounded())
        if pct >= 90 {
            return .ansi8(.green)
        } else if pct >= 75 {
            return .ansi8(.yellow)
        } else if pct >= 60 {
            return .truecolor(r: 255, g: 165, b: 0)
        } else {
            return .ansi8(.red)
        }
    }

    // MARK: - Trends Tab

    private static func renderTrends(into buf: inout ScreenBuffer, trends: [TrendPoint], width: Int) {
        buf.appendLine(boxRow("", width: width))
        if trends.isEmpty {
            buf.appendLine(boxRow("  No trend data available.", width: width))
        } else {
            let sparkWidth = min(width - 10, 50)
            let values = trends.map(\.value)
            let sparkline = InlineSparkline.render(
                data: values,
                width: sparkWidth,
                color: .ansi8(.cyan),
                min: 0.0,
                max: 1.0
            )

            buf.appendLine(boxRow("  Pass Rate Trend:", width: width))
            buf.appendLine(boxRow("", width: width))
            buf.appendLine(boxRow("  100% \(sparkline)", width: width))
            buf.appendLine(boxRow("    0% " + String(repeating: "\u{2500}", count: sparkWidth), width: width))

            buf.appendLine(boxRow("", width: width))

            if let latest = values.last, let earliest = values.first {
                let direction: String
                if abs(latest - earliest) < 1e-6 {
                    direction = "Stable"
                } else if latest > earliest {
                    direction = "\u{2191} Improving"
                } else {
                    direction = "\u{2193} Declining"
                }
                buf.appendLine(boxRow("  Direction: \(direction)  (\(trends.count) data points)", width: width))
            }
        }
        buf.appendLine(boxRow("", width: width))
    }

    // MARK: - Helpers

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
