import Foundation
import IJSDashboardCore
import IJSSensor

/// Renders dashboard summaries as formatted text or JSON.
public enum DashboardRenderer: Sendable {

    // MARK: - Portfolio View

    /// Renders a portfolio overview as formatted text.
    public static func renderPortfolio(_ portfolio: PortfolioSummary, projects: [ProjectSummary], pulse: InstitutionalPulse? = nil) -> String {
        var lines: [String] = []

        lines.append("═══════════════════════════════════════════════")
        lines.append("  IJS Portfolio Dashboard")
        lines.append("═══════════════════════════════════════════════")
        lines.append("")
        lines.append("  \(portfolio.totalProjects) projects | \(portfolio.passingProjects) passing | \(portfolio.failingProjects) failing")
        lines.append("")

        if !projects.isEmpty {
            lines.append("  Project                  Status   Pass Rate   Runs")
            lines.append("  ─────────────────────────────────────────────────────")
            for project in projects.sorted(by: { $0.passRate > $1.passRate }) {
                let status = project.latestPassed ? "✓" : "✗"
                let rate = formatPercent(project.passRate)
                let name = project.projectID.prefix(24).padding(toLength: 24, withPad: " ", startingAt: 0)
                lines.append("  \(name)  \(status)      \(rate.padding(toLength: 10, withPad: " ", startingAt: 0))  \(project.runCount)")
            }
            lines.append("")
        }

        if !portfolio.worstCheckers.isEmpty {
            lines.append("  Worst Checkers (across portfolio):")
            for checker in portfolio.worstCheckers.prefix(5) {
                lines.append("    - \(checker)")
            }
            lines.append("")
        }

        if let pulse {
            lines.append("  ─────────────────────────────────────────────────────")
            lines.append("  Pulse \(pulse.weekLabel)")
            lines.append("")
            let stats = pulse.statistics
            let passRateStr = stats.passRate.formatted(.number.precision(.fractionLength(1)))
            lines.append("  Gate Runs: \(stats.totalGateRuns)   Pass Rate: \(passRateStr)%")
            lines.append("  Overrides: \(stats.totalOverrides)   Calibrations: \(stats.totalCalibrations)")
            if let score = stats.meanConsistencyScore {
                let scoreStr = score.formatted(.number.precision(.fractionLength(2)))
                lines.append("  Consistency: \(scoreStr)")
            }
            lines.append("")

            if !pulse.violationClusters.isEmpty {
                lines.append("  Violation Clusters:")
                for cluster in pulse.violationClusters.prefix(5) {
                    let recurring = cluster.isRecurring ? " [RECURRING]" : ""
                    lines.append("    ✗ \(cluster.ruleId)  \(cluster.occurrenceCount)x across \(cluster.affectedProjectCount) project(s)\(recurring)")
                }
                lines.append("")
            }

            if !stats.anomalies.isEmpty {
                lines.append("  Anomalies:")
                for anomaly in stats.anomalies {
                    let direction = anomaly.direction == .negative ? "↓" : "↑"
                    let zStr = abs(anomaly.zScore).formatted(.number.precision(.fractionLength(2)))
                    lines.append("    ⚠ \(anomaly.metric): z=\(zStr) (\(anomaly.severity.rawValue), \(direction))")
                }
                lines.append("")
            }

            if let narrative = pulse.narrative, !narrative.isEmpty {
                lines.append("  Narrative:")
                lines.append("  \(narrative)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Project Detail View

    /// Renders a single project's detail view as formatted text.
    public static func renderProjectDetail(_ project: ProjectSummary, trends: [TrendPoint]) -> String {
        var lines: [String] = []

        let status = project.latestPassed ? "PASSING" : "FAILING"
        lines.append("═══════════════════════════════════════════════")
        lines.append("  \(project.projectID)")
        lines.append("═══════════════════════════════════════════════")
        lines.append("")
        lines.append("  Status:     \(status)")
        lines.append("  Pass Rate:  \(formatPercent(project.passRate))")
        lines.append("  Runs:       \(project.runCount)")
        lines.append("  Overrides:  \(project.totalOverrides)")
        lines.append("")

        if !project.checkerPassRates.isEmpty {
            lines.append("  Checker Breakdown:")
            lines.append("  ──────────────────────────────────")
            let sorted = project.checkerPassRates.sorted { $0.value < $1.value }
            for (checker, rate) in sorted {
                let indicator = abs(rate - 1.0) < 1e-6 ? "✓" : "✗"
                lines.append("    \(indicator) \(checker.padding(toLength: 20, withPad: " ", startingAt: 0)) \(formatPercent(rate))")
            }
            lines.append("")
        }

        if !trends.isEmpty {
            lines.append("  Trend (daily pass rate):")
            let sparkline = renderSparkline(trends.map(\.value))
            lines.append("    \(sparkline)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON Output

    /// Renders portfolio and project data as JSON.
    public static func renderJSON(portfolio: PortfolioSummary, projects: [ProjectSummary]) -> String {
        var dict: [String: Any] = [
            "totalProjects": portfolio.totalProjects,
            "passingProjects": portfolio.passingProjects,
            "failingProjects": portfolio.failingProjects,
            "worstCheckers": portfolio.worstCheckers,
        ]

        let projectDicts: [[String: Any]] = projects.map { p in
            [
                "projectID": p.projectID,
                "passRate": p.passRate,
                "latestPassed": p.latestPassed,
                "runCount": p.runCount,
                "totalOverrides": p.totalOverrides,
                "checkerPassRates": p.checkerPassRates,
            ]
        }
        dict["projects"] = projectDicts

        guard let data = try? JSONSerialization.data( // silent: JSON serialization of known-valid dictionary types cannot fail
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Private Helpers

    private static func formatPercent(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return "\(pct)%"
    }

    private static func renderSparkline(_ values: [Double]) -> String {
        let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        guard !values.isEmpty else { return "" }
        let maxVal = values.max() ?? 1.0
        let minVal = values.min() ?? 0.0
        let range = maxVal - minVal
        return values.map { v in
            if range < 1e-9 {
                return blocks[blocks.count / 2]
            }
            let normalized = (v - minVal) / range
            let idx = min(Int(normalized * Double(blocks.count - 1)), blocks.count - 1)
            return blocks[idx]
        }.joined()
    }
}
