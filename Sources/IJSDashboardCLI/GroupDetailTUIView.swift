import Foundation
import IJSDashboardCore
import IJSSensor
import SwiftCLIKit

/// Renders the group detail view showing group summary, member list, and optional trend.
public enum GroupDetailTUIView: Sendable {

    /// Produces a formatted string for the group detail view with summary, member table, and trend.
    public static func render(
        groupID: String,
        memberProjects: [ProjectSummary],
        groupSnapshots: [DailySnapshot]?,
        pulse: InstitutionalPulse?,
        state: DashboardState,
        width: Int
    ) -> String {
        let box = BoxDrawing.unicode
        var buf = ScreenBuffer(width: width)

        buf.appendLine(box.topBorder(" \(groupID) ", width: width))
        buf.appendLine(boxRow("", width: width))

        let memberCount = memberProjects.count
        let aggregatePassRate: Double
        if memberProjects.isEmpty {
            aggregatePassRate = 0
        } else {
            aggregatePassRate = memberProjects.reduce(0.0) { $0 + $1.passRate } / Double(memberCount) // fp-safety:disable guarded by isEmpty
        }
        let totalRuns = memberProjects.reduce(0) { $0 + $1.runCount }
        let allPassing = memberProjects.allSatisfy(\.latestPassed)
        let status = allPassing ? "PASSING" : "FAILING"
        let statusColor: ANSIColor = allPassing ? .green : .red
        let statusStyled = ANSICodes.bold + ANSICodes.fg(statusColor) + status + ANSICodes.reset

        let pctStr = formatPercent(aggregatePassRate)
        buf.appendLine(boxRow("  \(memberCount) members  |  \(statusStyled)  |  \(pctStr) pass rate  |  \(totalRuns) runs", width: width))
        buf.appendLine(boxRow("", width: width))

        // Member table
        buf.appendLine(box.midBorder(width: width))
        let nameWidth = min(max(width - 30, 16), 30)
        let header = "  " + "Project".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "Status  Pass Rate"
        buf.appendLine(boxRow(header, width: width))
        buf.appendLine(box.midBorder(width: width))

        let sorted = memberProjects.sorted { $0.projectID < $1.projectID }
        for (idx, project) in sorted.enumerated() {
            let isSelected = idx == state.selectedGroupMemberIndex
            let indicator = project.latestPassed ? "\u{2713}" : "\u{2717}"
            let indicatorColor = project.latestPassed ? ANSICodes.fg(.green) : ANSICodes.fg(.red)
            let pct = formatPercent(project.passRate)
            let name = String(project.projectID.prefix(nameWidth))
                .padding(toLength: nameWidth, withPad: " ", startingAt: 0)

            let memberRow = "  \(indicatorColor)\(indicator)\(ANSICodes.reset) \(name)\(pct)"

            if isSelected {
                buf.appendLine(boxRow(ANSICodes.reverse + memberRow + ANSICodes.reset, width: width))
            } else {
                buf.appendLine(boxRow(memberRow, width: width))
            }
        }
        buf.appendLine(boxRow("", width: width))

        // Group trend
        buf.appendLine(box.midBorder(width: width))
        if let snapshots = groupSnapshots, !snapshots.isEmpty {
            let sorted = snapshots.sorted { $0.date < $1.date }
            let values = sorted.map(\.passRate)
            let sparkWidth = min(width - 30, 40)
            let sparkline = InlineSparkline.render(
                data: values,
                width: max(sparkWidth, 10),
                color: .ansi8(.cyan),
                min: 0.0,
                max: 1.0
            )
            buf.appendLine(boxRow("  Group Trend (\(snapshots.count)d): \(sparkline)", width: width))
        } else {
            buf.appendLine(boxRow("  No trend data available.", width: width))
        }
        buf.appendLine(boxRow("", width: width))

        buf.appendLine(box.bottomBorder(width: width))

        let helpLine = ANSICodes.dim + "  \u{2191}\u{2193} Navigate  Enter Select  Esc Back  q Quit" + ANSICodes.reset
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
