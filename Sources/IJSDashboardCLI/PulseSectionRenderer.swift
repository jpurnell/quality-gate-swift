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

    /// Renders the top violation clusters with recurring indicators.
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

        for cluster in top {
            let recurring = cluster.isRecurring
                ? "  " + ANSICodes.fg(.red) + "[RECURRING]" + ANSICodes.reset
                : ""
            let indicator = ANSICodes.fg(.red) + "\u{2717}" + ANSICodes.reset
            lines.append(boxRow(
                "    \(indicator) \(cluster.ruleId)  \(cluster.occurrenceCount)x across \(cluster.affectedProjectCount) project(s)\(recurring)",
                width: width
            ))
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

        let innerWidth = width - 6
        let wrapped = wrapText(narrative, to: innerWidth)
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
        let padding = max(0, innerWidth - visLen)
        return box.vertical + content
            + String(repeating: " ", count: padding)
            + box.vertical
    }

    private static func wrapText(_ text: String, to maxWidth: Int) -> [String] {
        guard maxWidth > 0 else { return [text] }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var lines: [String] = []
        var current = ""

        for word in words {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if candidate.count <= maxWidth {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
