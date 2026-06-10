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
            let displayLabel = pulse.label ?? pulse.weekLabel
            let labelNav = renderLabelNavigator(state: state, label: displayLabel)
            buf.appendLine(boxRow("  " + labelNav + "  " + compactParts.joined(separator: "  "), width: width))
        }

        buf.appendLine(boxRow("", width: width))

        let anomalyByScope = buildAnomalyLookup(pulse: pulse)

        let visibleRows = state.visibleRows
        if !visibleRows.isEmpty {
            let nameWidth = min(max(width - 58, 16), 26)
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
                + "\(statusLabel)  \(healthLabel) \(runsLabel) Anomaly"
            buf.appendLine(boxRow(header, width: width))
            buf.appendLine(box.midBorder(width: width))

            let activeMap = Dictionary(uniqueKeysWithValues: active.map { ($0.projectID, $0) })

            for (idx, row) in visibleRows.enumerated() {
                let isSelected = idx == state.selectedIndex

                switch row {
                case .group(let groupID):
                    let isExpanded = state.expandedGroups.contains(groupID)
                    let arrow = isExpanded ? "\u{25BC}" : "\u{25B6}"
                    let members = state.groups[groupID] ?? []
                    let memberProjects = members.compactMap { activeMap[$0] }
                    let memberCount = memberProjects.count
                    let groupPassRate: Double
                    if memberProjects.isEmpty {
                        groupPassRate = 0
                    } else {
                        groupPassRate = memberProjects.reduce(0.0) { $0 + $1.passRate } / Double(memberCount) // fp-safety:disable guarded by isEmpty
                    }
                    let allPassing = memberProjects.allSatisfy(\.latestPassed)
                    let status = allPassing ? "\u{2713}" : "\u{2717}"
                    let pct = formatPercent(groupPassRate)
                    let label = "\(arrow) \(groupID) (\(memberCount))"
                    let name = String(label.prefix(nameWidth))
                        .padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                    let groupRow = "  \(name)  \(status)              \(pct.padding(toLength: 5, withPad: " ", startingAt: 0))"

                    if isSelected {
                        buf.appendLine(boxRow(ANSICodes.reverse + groupRow + ANSICodes.reset, width: width))
                    } else {
                        buf.appendLine(boxRow(ANSICodes.bold + groupRow + ANSICodes.reset, width: width))
                    }

                case .project(let projectID):
                    guard let project = activeMap[projectID] else { continue }
                    let isGroupMember = state.groups.values.contains { $0.contains(projectID) }
                    let indent = isGroupMember ? "    " : "  "
                    let effectiveNameWidth = isGroupMember ? nameWidth - 2 : nameWidth
                    let status = project.latestPassed ? "\u{2713}" : "\u{2717}"
                    let pct = formatPercent(project.passRate)
                    let name = String(project.projectID.prefix(effectiveNameWidth))
                        .padding(toLength: effectiveNameWidth, withPad: " ", startingAt: 0)

                    let runs = allRuns[project.projectID] ?? []
                    let timeline = renderHealthTimeline(runs: runs)
                    let anomalyTag = anomalyByScope[projectID] ?? ""

                    let projectRow = "\(indent)\(name)  \(status)     \(timeline) \(pct.padding(toLength: 5, withPad: " ", startingAt: 0))  \(String(describing: project.runCount).padding(toLength: 4, withPad: " ", startingAt: 0)) \(anomalyTag)"

                    if isSelected {
                        buf.appendLine(boxRow(ANSICodes.reverse + projectRow + ANSICodes.reset, width: width))
                    } else {
                        buf.appendLine(boxRow(projectRow, width: width))
                    }
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
            if let tiers = pulse.projectTiers {
                for line in PulseSectionRenderer.renderStratification(tiers, width: width) {
                    buf.appendLine(line)
                }
            }
            if let trajectories = pulse.projectTrajectories {
                for line in PulseSectionRenderer.renderTrajectories(trajectories, width: width) {
                    buf.appendLine(line)
                }
            }
            if let groupSnapshots = pulse.groupSnapshots {
                for line in PulseSectionRenderer.renderGroupSummary(groupSnapshots, width: width) {
                    buf.appendLine(line)
                }
            }
            for line in PulseSectionRenderer.renderClusters(pulse.violationClusters, width: width) {
                buf.appendLine(line)
            }
            for line in PulseSectionRenderer.renderNarrative(pulse.narrative, width: width) {
                buf.appendLine(line)
            }
        }

        buf.appendLine(box.bottomBorder(width: width))

        let helpLine = ANSICodes.dim + "  \u{2191}\u{2193} Navigate  \u{2190}\u{2192} Expand/Pulse  Enter Select  Scroll/PgUp/PgDn Viewport  s Sort  q Quit" + ANSICodes.reset
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

    private static func renderLabelNavigator(state: DashboardState, label: String) -> String {
        guard !state.availableLabels.isEmpty, let idx = state.selectedLabelIndex else {
            return "Pulse \(label):"
        }
        let left = idx > 0
            ? ANSICodes.bold + "\u{25C0}" + ANSICodes.reset
            : ANSICodes.dim + "\u{25C0}" + ANSICodes.reset
        let right = idx < state.availableLabels.count - 1
            ? ANSICodes.bold + "\u{25B6}" + ANSICodes.reset
            : ANSICodes.dim + "\u{25B6}" + ANSICodes.reset
        let position = "\(idx + 1)/\(state.availableLabels.count)"
        return "\(left) Pulse \(label) \(right)  (\(position))"
    }

    private static func buildAnomalyLookup(pulse: InstitutionalPulse?) -> [String: String] {
        guard let pulse else { return [:] }
        let anomalies = pulse.statistics.anomalies
        guard !anomalies.isEmpty else { return [:] }

        let grouped = Dictionary(grouping: anomalies, by: \.scope)
        var result: [String: String] = [:]

        for (scope, items) in grouped {
            let top = items.max { a, b in
                if a.severity != b.severity { return a.severity < b.severity }
                return abs(a.zScore) < abs(b.zScore)
            }
            guard let top else { continue }

            let severityColor: ANSIColor = switch top.severity {
            case .extreme: .red
            case .significant: .yellow
            case .notable: .cyan
            }
            let arrow = top.direction == .negative ? "\u{2193}" : "\u{2191}"
            let zStr = abs(top.zScore).formatted(.number.precision(.fractionLength(1)))
            let icon = ANSICodes.fg(severityColor) + "\u{26A0}" + ANSICodes.reset
            let metricShort: String = switch top.metric {
            case "passRate": "pass"
            case "failureRate": "fail"
            case "overrideRate": "ovrd"
            case "calibrationRate": "cal"
            default: String(top.metric.prefix(4))
            }
            result[scope] = "\(icon)\(metricShort) z\(zStr)\(arrow)"
        }

        return result
    }

    private static func formatPercent(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return "\(pct)%"
    }
}
