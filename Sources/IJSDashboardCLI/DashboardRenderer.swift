import Foundation
import IJSAggregator
import IJSDashboardCore
import IJSSensor
import os

/// Renders dashboard summaries as formatted text or JSON.
public enum DashboardRenderer: Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "DashboardRenderer")

    // MARK: - Portfolio View

    /// Renders a portfolio overview as formatted text.
    public static func renderPortfolio(_ portfolio: PortfolioSummary, projects: [ProjectSummary], pulse: InstitutionalPulse? = nil) -> String {
        var lines: [String] = []

        lines.append("═══════════════════════════════════════════════")
        lines.append("  IJS Portfolio Dashboard")
        lines.append("═══════════════════════════════════════════════")
        lines.append("")
        var statusParts = ["\(portfolio.totalProjects) active", "\(portfolio.passingProjects) passing", "\(portfolio.failingProjects) failing"]
        if portfolio.sunsetProjects > 0 {
            statusParts.append("\(portfolio.sunsetProjects) sunset")
        }
        lines.append("  " + statusParts.joined(separator: " | "))

        if let pulse {
            let stats = pulse.statistics
            let passRateStr = stats.passRate.formatted(.number.precision(.fractionLength(1)))
            let displayLabel = pulse.label ?? pulse.weekLabel
            lines.append("  Pulse \(displayLabel)   Gate Runs: \(stats.totalGateRuns)   Pass Rate: \(passRateStr)%   Overrides: \(stats.totalOverrides)   Calibrations: \(stats.totalCalibrations)\(stats.meanConsistencyScore.map { "   Consistency: \($0.formatted(.number.precision(.fractionLength(2))))" } ?? "")")
        }

        lines.append("")

        let active = projects.filter { $0.lifecycle == .active }
        let sunset = projects.filter { $0.lifecycle == .sunset }

        if !active.isEmpty {
            lines.append("  Project                  Status   Pass Rate   Runs")
            lines.append("  ─────────────────────────────────────────────────────")
            for project in active.sorted(by: { $0.passRate > $1.passRate }) {
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

        if !sunset.isEmpty {
            lines.append("  ─────────────────────────────────────────────────────")
            lines.append("  Sunset Projects (\(sunset.count)):")
            let names = sunset.sorted(by: { $0.projectID < $1.projectID }).map(\.projectID)
            for chunk in stride(from: 0, to: names.count, by: 3) {
                let end = min(chunk + 3, names.count)
                lines.append("    " + names[chunk..<end].joined(separator: ", "))
            }
            lines.append("")
        }

        if let pulse {
            lines.append("  ─────────────────────────────────────────────────────")
            lines.append("")

            if let tiers = pulse.projectTiers, !tiers.isEmpty {
                var tierCounts: [ProjectTier: Int] = [:]
                for tier in tiers.values { tierCounts[tier, default: 0] += 1 }
                let ordered: [ProjectTier] = [.active, .baseline, .firstContact, .atRisk, .dormant]
                let parts = ordered.compactMap { tier -> String? in
                    guard let count = tierCounts[tier], count > 0 else { return nil }
                    return "\(count) \(tier.rawValue)"
                }
                lines.append("  Tiers: \(parts.joined(separator: "  "))")
            }

            if let ws = pulse.statistics.weightedScores {
                let vals = ws.values.sorted()
                let count = Double(vals.count)
                if count > 0 {
                let mean = vals.reduce(0, +) / count
                let meanStr = mean.formatted(.number.precision(.fractionLength(3)))
                let minStr = (vals.first ?? 0).formatted(.number.precision(.fractionLength(3)))
                let maxStr = (vals.last ?? 0).formatted(.number.precision(.fractionLength(3)))
                lines.append("  Weighted Score: mean \(meanStr)  range \(minStr)–\(maxStr)")
                }
            }

            if let trajs = pulse.projectTrajectories, !trajs.isEmpty {
                var dirCounts: [String: Int] = [:]
                for t in trajs { dirCounts[t.direction.rawValue, default: 0] += 1 }
                let ordered = ["improving", "stable", "declining", "insufficient"]
                let parts = ordered.compactMap { dir -> String? in
                    guard let count = dirCounts[dir], count > 0 else { return nil }
                    return "\(count) \(dir)"
                }
                lines.append("  Trajectories: \(parts.joined(separator: "  "))")
            }

            if let gs = pulse.groupSnapshots, !gs.isEmpty {
                lines.append("  Groups:")
                for group in gs.keys.sorted() {
                    guard let snaps = gs[group], let latest = snaps.sorted(by: { $0.date < $1.date }).last else { continue }
                    let pct = Int((latest.passRate * 100).rounded())
                    lines.append("    \(group): \(pct)% (\(latest.gateRuns) runs)")
                }
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

            if !pulse.statistics.anomalies.isEmpty {
                lines.append("  Anomalies:")
                for anomaly in pulse.statistics.anomalies {
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

        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            logger.warning("Failed to serialize portfolio JSON: \(error.localizedDescription, privacy: .public)")
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
