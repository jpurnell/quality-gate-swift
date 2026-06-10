import Foundation
import IJSDashboardCore
import IJSSensor
import SwiftCLIKit

/// Renders pulse data sections as box-row formatted lines for the portfolio TUI view.
///
/// Each method returns an array of pre-formatted strings ready to be appended
/// to a ``ScreenBuffer``. Returns an empty array when there is no data to display.
public enum PulseSectionRenderer: Sendable {

    /// Renders pulse statistics: gate runs, pass rate gauge, overrides, calibrations, consistency.
    ///
    /// - Parameters:
    ///   - stats: The pulse statistics to render.
    ///   - label: Pulse label (date or week) for the header.
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines for the statistics section.
    public static func renderStatistics(
        _ stats: PulseStatistics,
        label: String,
        width: Int
    ) -> [String] {
        var lines: [String] = []

        lines.append(boxRow("  Pulse \(label)", width: width))
        lines.append(boxRow("", width: width))

        let passRateStr = stats.passRate.formatted(.number.precision(.fractionLength(1)))
        let gaugeWidth = min(width - 50, 20)
        let gauge = InlineGauge.renderWithLabel(
            current: Int(stats.passRate.rounded()),
            total: 100,
            width: max(gaugeWidth, 10),
            filledColor: stats.passRate >= 70 ? .ansi8(.green) : .ansi8(.red)
        )
        lines.append(boxRow("  Gate Runs: \(stats.totalGateRuns)   Pass Rate: \(gauge)  \(passRateStr)%", width: width))

        lines.append(boxRow(
            "  Overrides: \(stats.totalOverrides)     Calibrations: \(stats.totalCalibrations)",
            width: width
        ))

        if let score = stats.meanConsistencyScore {
            let scoreStr = score.formatted(.number.precision(.fractionLength(2)))
            lines.append(boxRow("  Consistency: \(scoreStr)", width: width))
        }

        lines.append(boxRow("", width: width))
        return lines
    }

    /// Renders the top violation clusters as a three-column table.
    ///
    /// - Parameters:
    ///   - clusters: Violation clusters to render (limited to top 5).
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines, or empty array if no clusters.
    public static func renderClusters(
        _ clusters: [ViolationCluster],
        width: Int
    ) -> [String] {
        let top = Array(clusters.prefix(5))
        guard !top.isEmpty else { return [] }

        var lines: [String] = []
        lines.append(boxRow("  Violation Clusters:", width: width))

        let ruleWidth = computeRuleColumnWidth(top, maxWidth: width)
        let colWidth = 14

        let header = "    "
            + "Rule".padding(toLength: ruleWidth, withPad: " ", startingAt: 0)
            + "Last Wk".padding(toLength: colWidth, withPad: " ", startingAt: 0)
            + "This Wk".padding(toLength: colWidth, withPad: " ", startingAt: 0)
            + "Current"
        lines.append(boxRow(header, width: width))

        let divider = "    "
            + String(repeating: "\u{2500}", count: ruleWidth - 1) + " "
            + String(repeating: "\u{2500}", count: colWidth - 1) + " "
            + String(repeating: "\u{2500}", count: colWidth - 1) + " "
            + String(repeating: "\u{2500}", count: colWidth - 1)
        lines.append(boxRow(divider, width: width))

        for cluster in top {
            let rule = String(cluster.ruleId.prefix(ruleWidth - 1))
                .padding(toLength: ruleWidth, withPad: " ", startingAt: 0)

            let lastWeek: String
            if let prior = cluster.priorOccurrenceCount,
               let priorProj = cluster.priorProjectCount {
                lastWeek = "\(prior)x/\(priorProj)p"
            } else if cluster.isRecurring {
                lastWeek = "?"
            } else {
                lastWeek = ANSICodes.fg(.cyan) + "NEW" + ANSICodes.reset
            }

            let thisWeek = "\(cluster.occurrenceCount)x/\(cluster.affectedProjectCount)p"

            let current: String
            if let cur = cluster.currentOccurrenceCount,
               let curProj = cluster.currentProjectCount {
                if cur == 0 {
                    current = ANSICodes.fg(.green) + "RESOLVED" + ANSICodes.reset
                } else {
                    current = "\(cur)x/\(curProj)p"
                }
            } else {
                current = ANSICodes.dim + "N/A" + ANSICodes.reset
            }

            let lastWeekPad = padVisible(lastWeek, to: colWidth)
            let thisWeekPad = padVisible(thisWeek, to: colWidth)

            let row = "    " + rule + lastWeekPad + thisWeekPad + current
            lines.append(boxRow(row, width: width))
        }

        lines.append(boxRow("", width: width))
        return lines
    }

    /// Renders statistical anomaly alerts grouped by project, showing the
    /// highest-severity anomaly per project with a summary of additional signals.
    ///
    /// - Parameters:
    ///   - anomalies: Anomalies to render.
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines, or empty array if no anomalies.
    public static func renderAnomalies(
        _ anomalies: [StatisticalAnomaly],
        width: Int
    ) -> [String] {
        guard !anomalies.isEmpty else { return [] }

        let grouped = Dictionary(grouping: anomalies, by: \.scope)
        let projectCount = grouped.count
        let totalCount = anomalies.count

        struct ProjectSummary {
            let scope: String
            let top: StatisticalAnomaly
            let otherMetrics: [String]
            let count: Int
        }

        let summaries: [ProjectSummary] = grouped.map { scope, items in
            let sorted = items.sorted { a, b in
                if a.severity != b.severity { return a.severity > b.severity }
                return abs(a.zScore) > abs(b.zScore)
            }
            let top = sorted[0]
            let others = sorted.dropFirst().map { a in
                let arrow = a.direction == .negative ? "\u{2193}" : "\u{2191}"
                return "\(a.metric)\(arrow)"
            }
            let uniqueOthers = Array(Set(others)).sorted()
            return ProjectSummary(scope: scope, top: top, otherMetrics: uniqueOthers, count: items.count)
        }.sorted { a, b in
            if a.top.severity != b.top.severity { return a.top.severity > b.top.severity }
            return abs(a.top.zScore) > abs(b.top.zScore)
        }

        let maxNameLen = min(summaries.map(\.scope.count).max() ?? 0, 28)

        var lines: [String] = []
        lines.append(boxRow("  Anomalies (\(projectCount) projects, \(totalCount) signals):", width: width))

        for summary in summaries {
            let a = summary.top
            let isGood = a.direction == .positive
            let directionArrow = a.direction == .negative ? "\u{2193}" : "\u{2191}"
            let zStr = abs(a.zScore).formatted(.number.precision(.fractionLength(2)))
            let icon: String
            if isGood {
                icon = ANSICodes.fg(.green) + "\u{2713}" + ANSICodes.reset
            } else {
                let z = abs(a.zScore)
                let color: String = if z > 2.576 {
                    ANSICodes.fg(.red)
                } else if z >= 1.96 {
                    ANSICodes.fg(.yellow)
                } else {
                    ANSICodes.fg(.cyan)
                }
                icon = color + "\u{26A0}" + ANSICodes.reset
            }
            let name = summary.scope.padding(toLength: maxNameLen, withPad: " ", startingAt: 0)
            let detail = "\(a.metric) z=\(zStr) (\(a.severity.rawValue), \(directionArrow))"

            if summary.count > 1 {
                let extras = summary.otherMetrics.prefix(3).joined(separator: ", ")
                lines.append(boxRow("    \(icon) \(name)  \(detail)  +\(summary.count - 1) more: \(extras)", width: width))
            } else {
                lines.append(boxRow("    \(icon) \(name)  \(detail)", width: width))
            }
        }

        lines.append(boxRow("", width: width))
        return lines
    }

    /// Renders the narrative text, word-wrapped to terminal width.
    ///
    /// Strips markdown formatting for clean TUI display.
    ///
    /// - Parameters:
    ///   - narrative: The narrative string, or nil if not yet generated.
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines, or empty array if narrative is nil.
    public static func renderNarrative(
        _ narrative: String?,
        width: Int
    ) -> [String] {
        guard let narrative, !narrative.isEmpty else { return [] }

        var lines: [String] = []
        lines.append(boxRow("  Narrative:", width: width))

        let cleaned = stripMarkdown(narrative)
        let innerWidth = width - 6
        let wrapped = wrapText(cleaned, to: innerWidth)
        for line in wrapped {
            lines.append(boxRow("  \(line)", width: width))
        }

        lines.append(boxRow("", width: width))
        return lines
    }

    /// Renders a corpus-level trend sparkline from daily snapshots.
    ///
    /// - Parameters:
    ///   - snapshots: Daily snapshots sorted by date.
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines, or empty array if no snapshots.
    public static func renderCorpusTrend(
        _ snapshots: [DailySnapshot],
        width: Int
    ) -> [String] {
        guard !snapshots.isEmpty else { return [] }

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

        var lines: [String] = []
        lines.append(boxRow("  Corpus Trend (\(snapshots.count)d): \(sparkline)", width: width))
        lines.append(boxRow("", width: width))
        return lines
    }

    /// Renders project tier stratification showing count per tier.
    ///
    /// - Parameters:
    ///   - tiers: Project tier classifications keyed by project ID.
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines, or empty array if no tiers.
    public static func renderStratification(
        _ tiers: [String: ProjectTier],
        width: Int
    ) -> [String] {
        guard !tiers.isEmpty else { return [] }

        var counts: [ProjectTier: Int] = [:]
        for tier in tiers.values {
            counts[tier, default: 0] += 1
        }

        let ordered: [ProjectTier] = [.active, .baseline, .firstContact, .atRisk, .dormant]
        let parts = ordered.compactMap { tier -> String? in
            guard let count = counts[tier], count > 0 else { return nil }
            return "\(count) \(tier.rawValue)"
        }

        var lines: [String] = []
        lines.append(boxRow("  Tiers: \(parts.joined(separator: "  "))", width: width))
        lines.append(boxRow("", width: width))
        return lines
    }

    /// Renders project trajectory summary with direction counts and top movers.
    ///
    /// - Parameters:
    ///   - trajectories: Per-project trajectory analyses.
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines, or empty array if no trajectories.
    public static func renderTrajectories(
        _ trajectories: [ProjectTrajectory],
        width: Int
    ) -> [String] {
        guard !trajectories.isEmpty else { return [] }

        var directionCounts: [TrajectoryDirection: Int] = [:]
        for traj in trajectories {
            directionCounts[traj.direction, default: 0] += 1
        }

        let directionOrder: [TrajectoryDirection] = [.improving, .stable, .declining, .insufficient]
        let arrows: [TrajectoryDirection: String] = [
            .improving: "\u{2191}",
            .stable: "\u{2192}",
            .declining: "\u{2193}",
            .insufficient: "?",
        ]
        let parts = directionOrder.compactMap { dir -> String? in
            guard let count = directionCounts[dir], count > 0 else { return nil }
            return "\(arrows[dir] ?? "") \(count) \(dir.rawValue)"
        }

        var lines: [String] = []
        lines.append(boxRow("  Trajectories: \(parts.joined(separator: "  "))", width: width))

        // Show top movers (largest absolute slope among valid trajectories)
        let validTrajectories = trajectories
            .filter { $0.direction != .insufficient }
            .sorted { abs($0.slope) > abs($1.slope) }
        let topMovers = Array(validTrajectories.prefix(3))
        if !topMovers.isEmpty {
            let moverParts = topMovers.map { traj in
                let arrow = traj.slope >= 0 ? "\u{2191}" : "\u{2193}"
                let slopeStr = abs(traj.slope).formatted(.number.precision(.fractionLength(3)))
                return "\(traj.projectID) \(arrow)\(slopeStr)"
            }
            lines.append(boxRow("    Top movers: \(moverParts.joined(separator: "  "))", width: width))
        }

        lines.append(boxRow("", width: width))
        return lines
    }

    /// Renders group summary showing each group with its latest day's pass rate.
    ///
    /// - Parameters:
    ///   - groupSnapshots: Group-level snapshots keyed by group ID.
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines, or empty array if no groups.
    public static func renderGroupSummary(
        _ groupSnapshots: [String: [DailySnapshot]],
        width: Int
    ) -> [String] {
        guard !groupSnapshots.isEmpty else { return [] }

        var lines: [String] = []
        lines.append(boxRow("  Groups:", width: width))

        let sortedGroups = groupSnapshots.keys.sorted()
        for group in sortedGroups {
            guard let snapshots = groupSnapshots[group], !snapshots.isEmpty else { continue }
            guard let latest = snapshots.sorted(by: { $0.date < $1.date }).last else { continue }
            let pct = Int((latest.passRate * 100).rounded())
            let color: ANSIColor = pct >= 70 ? .green : (pct >= 50 ? .yellow : .red)
            let coloredPct = ANSICodes.fg(color) + "\(pct)%" + ANSICodes.reset
            lines.append(boxRow("    \(group): \(coloredPct) (\(latest.gateRuns) runs)", width: width))
        }

        lines.append(boxRow("", width: width))
        return lines
    }

    // MARK: - Private

    private static func boxRow(_ content: String, width: Int) -> String {
        let box = BoxDrawing.unicode
        let visLen = ANSIStringMetrics.visibleLength(content)
        let innerWidth = width - 2
        if visLen >= innerWidth {
            let truncated = ANSIStringMetrics.truncateVisible(content, to: innerWidth - 1)
            let truncLen = ANSIStringMetrics.visibleLength(truncated)
            let pad = max(0, innerWidth - truncLen)
            return box.vertical + truncated
                + String(repeating: " ", count: pad)
                + box.vertical
        }
        let padding = innerWidth - visLen
        return box.vertical + content
            + String(repeating: " ", count: padding)
            + box.vertical
    }

    private static func wrapText(_ text: String, to maxWidth: Int) -> [String] {
        guard maxWidth > 0 else { return [text] }
        var result: [String] = []
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: false)
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append("")
                continue
            }
            let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
                if candidate.count <= maxWidth {
                    current = candidate
                } else {
                    if !current.isEmpty { result.append(current) }
                    if word.count > maxWidth {
                        var remaining = String(word)
                        while remaining.count > maxWidth {
                            result.append(String(remaining.prefix(maxWidth)))
                            remaining = String(remaining.dropFirst(maxWidth))
                        }
                        current = remaining
                    } else {
                        current = String(word)
                    }
                }
            }
            if !current.isEmpty { result.append(current) }
        }
        return result
    }

    private static func stripMarkdown(_ text: String) -> String {
        var result = text

        // Remove YAML frontmatter
        if result.hasPrefix("---") {
            if let endRange = result.range(of: "\n---\n", range: result.index(result.startIndex, offsetBy: 3)..<result.endIndex) {
                result = String(result[endRange.upperBound...])
            }
        }

        // Remove markdown tables (pipe-delimited rows and separator rows)
        let tablePattern = #"^\|.+\|$"#
        let separatorPattern = #"^\|[\s\-\|:]+\|$"#
        result = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.range(of: separatorPattern, options: .regularExpression) != nil {
                    return false
                }
                if trimmed.range(of: tablePattern, options: .regularExpression) != nil {
                    return false
                }
                return true
            }
            .joined(separator: "\n")

        // Convert ## headers to plain text with emphasis
        result = result.replacingOccurrences(
            of: #"^#{1,3}\s+"#,
            with: "",
            options: .regularExpression
        )

        // Strip bold markers
        result = result.replacingOccurrences(of: "**", with: "")

        // Strip italic markers (single *)
        result = result.replacingOccurrences(
            of: #"(?<!\*)\*(?!\*)"#,
            with: "",
            options: .regularExpression
        )

        // Strip backticks
        result = result.replacingOccurrences(of: "`", with: "")

        // Collapse multiple blank lines
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func computeRuleColumnWidth(
        _ clusters: [ViolationCluster],
        maxWidth: Int
    ) -> Int {
        let longest = clusters.map(\.ruleId.count).max() ?? 20
        let available = maxWidth - 52
        return min(max(longest + 2, 20), max(available, 20))
    }

    private static func padVisible(_ text: String, to width: Int) -> String {
        let visLen = ANSIStringMetrics.visibleLength(text)
        let pad = max(0, width - visLen)
        return text + String(repeating: " ", count: pad)
    }
}
