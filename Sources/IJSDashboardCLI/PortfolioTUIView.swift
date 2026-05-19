import Foundation
import IJSAggregator
import IJSDashboardCore
import IJSSensor
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
        width: Int,
        pulse: InstitutionalPulse? = nil
    ) -> String {
        let box = BoxDrawing.unicode
        var buf = ScreenBuffer(width: width)

        let active = projects.filter { $0.lifecycle == .active }
        let sunset = projects.filter { $0.lifecycle == .sunset }

        buf.appendLine(box.topBorder(" IJS Portfolio Dashboard ", width: width))
        buf.appendLine(boxRow("", width: width))

        var statusParts = ["\(portfolio.totalProjects) active", "\(portfolio.passingProjects) passing", "\(portfolio.failingProjects) failing"]
        if portfolio.sunsetProjects > 0 {
            statusParts.append("\(portfolio.sunsetProjects) sunset")
        }
        let statusLine = "  " + statusParts.joined(separator: " | ")
        buf.appendLine(boxRow(statusLine, width: width))

        if let pulse {
            let stats = pulse.statistics
            let passRateStr = stats.passRate.formatted(.number.precision(.fractionLength(1)))
            var compactParts = [
                "\(stats.totalGateRuns) runs",
                "\(passRateStr)% pass",
                "\(stats.totalOverrides) overrides",
            ]
            if let score = stats.meanConsistencyScore {
                let scoreStr = score.formatted(.number.precision(.fractionLength(2)))
                compactParts.append("Consistency: \(scoreStr)")
            }
            let weekNav = renderWeekNavigator(state: state, weekLabel: pulse.weekLabel)
            buf.appendLine(boxRow("  " + weekNav + "  " + compactParts.joined(separator: "  "), width: width))
        }

        buf.appendLine(boxRow("", width: width))

        if !active.isEmpty {
            let nameWidth = min(max(width - 40, 16), 30)
            let sortIndicator = state.sortAscending ? "\u{25B2}" : "\u{25BC}"
            let nameLabel = state.sortKey == .name
                ? "Project \(sortIndicator)" : "Project  "
            let statusLabel = state.sortKey == .status
                ? "Status\(sortIndicator)" : "Status "
            let healthLabel = state.sortKey == .passRate
                ? "Health    \(sortIndicator)" : "Health     "
            let runsLabel = state.sortKey == .runs
                ? "Runs\(sortIndicator)" : "Runs "
            let header = "  " + nameLabel.padding(toLength: nameWidth + 2, withPad: " ", startingAt: 0)
                + "\(statusLabel)  \(healthLabel) \(runsLabel)"
            buf.appendLine(boxRow(header, width: width))
            buf.appendLine(box.midBorder(width: width))

            let activeMap = Dictionary(uniqueKeysWithValues: active.map { ($0.projectID, $0) })
            let sorted = state.projectIDs.compactMap { activeMap[$0] }
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

        if !sunset.isEmpty {
            buf.appendLine(box.midBorder(width: width))
            let dimOn = ANSICodes.dim
            let dimOff = ANSICodes.reset
            buf.appendLine(boxRow("  \(dimOn)Sunset Projects (\(sunset.count)):\(dimOff)", width: width))
            let names = sunset.sorted { $0.projectID < $1.projectID }.map(\.projectID)
            let nameWidth = min(max(width - 10, 16), 30)
            for chunk in stride(from: 0, to: names.count, by: 3) {
                let end = min(chunk + 3, names.count)
                let line = names[chunk..<end].map { String($0.prefix(nameWidth)) }.joined(separator: ", ")
                buf.appendLine(boxRow("    \(dimOn)\(line)\(dimOff)", width: width))
            }
            buf.appendLine(boxRow("", width: width))
        }

        if let pulse {
            buf.appendLine(box.midBorder(width: width))
            let stats = pulse.statistics
            for line in PulseSectionRenderer.renderCorpusTrend(stats.corpusSnapshots, width: width) {
                buf.appendLine(line)
            }
            for line in PulseSectionRenderer.renderClusters(pulse.violationClusters, width: width) {
                buf.appendLine(line)
            }
            for line in PulseSectionRenderer.renderAnomalies(stats.anomalies, width: width) {
                buf.appendLine(line)
            }
            for line in PulseSectionRenderer.renderNarrative(pulse.narrative, width: width) {
                buf.appendLine(line)
            }
        }

        buf.appendLine(box.bottomBorder(width: width))

        let helpLine = ANSICodes.dim + "  \u{2191}\u{2193} Navigate  \u{2190}\u{2192} Week  Scroll/PgUp/PgDn Viewport  Enter Select  s Sort  q Quit" + ANSICodes.reset
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

    /// Returns active project IDs in the order defined by the current sort key.
    public static func sortedActiveIDs(
        from projects: [ProjectSummary],
        sortKey: SortKey,
        sortAscending: Bool
    ) -> [String] {
        let active = projects.filter { $0.lifecycle == .active }
        let sorted: [ProjectSummary]
        switch sortKey {
        case .name:
            sorted = sortAscending
                ? active.sorted { $0.projectID < $1.projectID }
                : active.sorted { $0.projectID > $1.projectID }
        case .status:
            sorted = sortAscending
                ? active.sorted { lhs, rhs in
                    if lhs.latestPassed != rhs.latestPassed { return !lhs.latestPassed }
                    return lhs.projectID < rhs.projectID
                  }
                : active.sorted { lhs, rhs in
                    if lhs.latestPassed != rhs.latestPassed { return lhs.latestPassed }
                    return lhs.projectID < rhs.projectID
                  }
        case .passRate:
            sorted = sortAscending
                ? active.sorted { $0.passRate < $1.passRate }
                : active.sorted { $0.passRate > $1.passRate }
        case .runs:
            sorted = sortAscending
                ? active.sorted { $0.runCount < $1.runCount }
                : active.sorted { $0.runCount > $1.runCount }
        }
        return sorted.map(\.projectID)
    }

    private static func renderWeekNavigator(state: DashboardState, weekLabel: String) -> String {
        guard !state.availableWeeks.isEmpty, let idx = state.selectedWeekIndex else {
            return "Pulse \(weekLabel):"
        }
        let left = idx > 0
            ? ANSICodes.bold + "\u{25C0}" + ANSICodes.reset
            : ANSICodes.dim + "\u{25C0}" + ANSICodes.reset
        let right = idx < state.availableWeeks.count - 1
            ? ANSICodes.bold + "\u{25B6}" + ANSICodes.reset
            : ANSICodes.dim + "\u{25B6}" + ANSICodes.reset
        let position = "\(idx + 1)/\(state.availableWeeks.count)"
        return "\(left) Pulse \(weekLabel) \(right)  (\(position))"
    }

    private static func formatPercent(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return "\(pct)%"
    }
}
