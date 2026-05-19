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
    ///   - weekLabel: ISO week label for the header.
    ///   - width: Terminal width for formatting.
    /// - Returns: Formatted lines for the statistics section.
    public static func renderStatistics(
        _ stats: PulseStatistics,
        weekLabel: String,
        width: Int
    ) -> [String] {
        var lines: [String] = []

        lines.append(boxRow("  Pulse \(weekLabel)", width: width))
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

    /// Renders statistical anomaly alerts with severity coloring.
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

        var lines: [String] = []
        lines.append(boxRow("  Anomalies:", width: width))

        for anomaly in anomalies {
            let severityColor: ANSIColor = switch anomaly.severity {
            case .extreme: .red
            case .significant: .yellow
            case .notable: .cyan
            }
            let directionArrow = anomaly.direction == .negative ? "\u{2193}" : "\u{2191}"
            let zStr = abs(anomaly.zScore).formatted(.number.precision(.fractionLength(2)))
            let icon = ANSICodes.fg(severityColor) + "\u{26A0}" + ANSICodes.reset
            lines.append(boxRow(
                "    \(icon) \(anomaly.metric): z=\(zStr) (\(anomaly.severity.rawValue), \(directionArrow))",
                width: width
            ))
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
