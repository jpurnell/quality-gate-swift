import Foundation
import IJSAggregator
import IJSDashboardCore
import IJSSensor
import SwiftCLIKit

/// Renders the project detail view with tabbed content as a box-drawn terminal frame.
public enum ProjectDetailTUIView: Sendable {

    /// Produces a formatted string for the project detail view with the active tab's content.
    public static func render(
        project: ProjectSummary,
        trends: [TrendPoint],
        runs: [TimestampedRun],
        state: DashboardState,
        width: Int,
        pulse: InstitutionalPulse? = nil,
        manifest: CorpusManifest = CorpusManifest()
    ) -> String {
        var buf = ScreenBuffer(width: width)

        let titleHeader = " \(project.projectID) "
        buf.appendLine(DashboardChrome.titleRule(titleHeader, width: width))
        buf.appendLine(boxRow("", width: width))

        renderTabBar(into: &buf, selectedTab: state.selectedTab, width: width)
        buf.appendLine(DashboardChrome.sectionRule(width: width))

        switch state.selectedTab {
        case .summary:
            // Overview, Trends, and Status are stacked as titled sections on one
            // scrollable page. The Summary stats need no title of their own — the
            // active tab is already labeled "Summary".
            renderOverview(into: &buf, project: project, width: width)
            renderModuleOrientation(into: &buf, project: project, width: width)
            renderTrends(into: &buf, trends: trends, width: width)
            renderStatus(into: &buf, project: project, state: state, width: width, pulse: pulse, manifest: manifest)
        case .checkers:
            renderCheckers(into: &buf, project: project, runs: runs, width: width)
        }

        buf.appendLine(DashboardChrome.sectionRule(width: width))

        let helpLine = ANSICodes.dim + "  \u{2190}/\u{2192} Switch tabs  \u{2191}/\u{2193} Scroll  Esc Back  q Quit" + ANSICodes.reset
        buf.appendLine(helpLine)

        return buf.raw
    }

    // MARK: - Tab Bar

    private static func renderTabBar(into buf: inout ScreenBuffer, selectedTab: DetailTab, width: Int) {
        // Indent and gap mirror ``DetailTabBar`` so the drawn labels line up with
        // the clickable column ranges computed by ``DetailTabBar/regions()``.
        let gap = String(repeating: " ", count: DetailTabBar.gap)
        var tabLine = String(repeating: " ", count: DetailTabBar.indent)
        for tab in DetailTab.allCases {
            if tab == selectedTab {
                tabLine += ANSICodes.bold + ANSICodes.underline + tab.label + ANSICodes.reset + gap
            } else {
                tabLine += ANSICodes.dim + tab.label + ANSICodes.reset + gap
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
        // Second-writer tripwire (Phase 2 §4b): the standing warning is the
        // first thing a reader sees until Phase 3 controls exist.
        if let census = project.writerCensus, census.tripped {
            let writers = census.persons.joined(separator: ", ")
            let styled = ANSICodes.bold + ANSICodes.fg(.yellow)
                + "⚠ MULTI-WRITER (\(writers)) — Phase 3 controls required"
                + ANSICodes.reset
            buf.appendLine(boxRow("  " + styled, width: width))
            buf.appendLine(boxRow("", width: width))
        }
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

        // Decaying baseline (Phase 4c §3): recorded debt is visible until it
        // burns down — and expiry is louder than coverage.
        if let baseline = project.latestBaseline {
            var line = "  Baseline:    \(baseline.baselined) debt(s)"
            if baseline.expired > 0 {
                line += " · " + ANSICodes.bold + ANSICodes.fg(.yellow)
                    + "\(baseline.expired) EXPIRED" + ANSICodes.reset
            }
            if baseline.newFindings > 0 {
                line += " · \(baseline.newFindings) new gating"
            }
            let trail = project.baselineBurnDown.suffix(6).map { "\($0.baselined)" }
            if trail.count > 1 {
                line += " · burn-down " + trail.joined(separator: " → ")
            }
            buf.appendLine(boxRow(line, width: width))
        }

        if let worst = project.worstChecker {
            buf.appendLine(boxRow("  Worst:       \(worst)", width: width))
        }
        buf.appendLine(boxRow("", width: width))
    }

    // MARK: - Orientation

    /// Renders the product-composition orientation: what it does, its portfolio
    /// role, what it is built from, and what relies on it. No-op when the project
    /// has no orientation card.
    private static func renderModuleOrientation(into buf: inout ScreenBuffer, project: ProjectSummary, width: Int) {
        guard let card = project.orientation else { return }
        buf.appendLine(DashboardChrome.titleRule("Orientation", width: width))
        buf.appendLine(boxRow("", width: width))
        if let what = card.whatItDoes {
            buf.appendLine(boxRow("  What it does: \(what)", width: width))
        }
        buf.appendLine(boxRow("  Role:         \(card.role)", width: width))
        if !card.dependsOn.isEmpty {
            buf.appendLine(boxRow("  Built from:   \(joinElided(card.dependsOn))", width: width))
        }
        if !card.reliedOnBy.isEmpty {
            buf.appendLine(boxRow("  Relied on by: \(joinElided(card.reliedOnBy))", width: width))
        }
        if let why = card.why {
            buf.appendLine(boxRow("  Why:          \(why)", width: width))
        }
        buf.appendLine(boxRow("", width: width))
    }

    /// Joins a list, truncating past `max` items with a "(+N more)" tail.
    private static func joinElided(_ items: [String], max: Int = 6) -> String {
        guard items.count > max else { return items.joined(separator: ", ") }
        let shown = items.prefix(max).joined(separator: ", ")
        return "\(shown) (+\(items.count - max) more)"
    }

    // MARK: - Checkers Tab

    private static let gaugeWidth = 15

    private static func renderCheckers(
        into buf: inout ScreenBuffer,
        project: ProjectSummary,
        runs: [TimestampedRun],
        width: Int
    ) {
        buf.appendLine(boxRow("", width: width))
        if project.checkerPassRates.isEmpty {
            buf.appendLine(boxRow("  No checker data available.", width: width))
        } else {
            let sorted = project.checkerPassRates.sorted { $0.value < $1.value }

            for (checker, rate) in sorted {
                let passingNow = project.latestCheckerPassed[checker] ?? false
                let indicator = passingNow ? "\u{2713}" : "\u{2717}"
                let indicatorColor = passingNow ? ANSICodes.fg(.green) : ANSICodes.fg(.red)
                let pctStr = formatPercent(rate)
                let name = checker.padding(toLength: 22, withPad: " ", startingAt: 0)
                let gauge = renderPassFailGauge(rate: rate, width: gaugeWidth)
                buf.appendLine(boxRow("  \(indicatorColor)\(indicator)\(ANSICodes.reset) \(name) \(gauge) \(pctStr)", width: width))
            }
        }
        buf.appendLine(boxRow("", width: width))
    }

    private static func renderPassFailGauge(rate: Double, width: Int) -> String {
        let passCount = Int((rate * Double(width)).rounded())
        let failCount = width - passCount
        var gauge = ""
        if failCount > 0 {
            gauge += ANSICodes.fg(.red) + String(repeating: "\u{2588}", count: failCount) + ANSICodes.reset
        }
        if passCount > 0 {
            gauge += ANSICodes.fg(.green) + String(repeating: "\u{2588}", count: passCount) + ANSICodes.reset
        }
        return gauge
    }

    // MARK: - Trends Tab

    private static func renderTrends(into buf: inout ScreenBuffer, trends: [TrendPoint], width: Int) {
        buf.appendLine(DashboardChrome.titleRule("Trends", width: width))
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

    // MARK: - Status Tab

    private static func renderStatus(
        into buf: inout ScreenBuffer,
        project: ProjectSummary,
        state: DashboardState,
        width: Int,
        pulse: InstitutionalPulse?,
        manifest: CorpusManifest
    ) {
        buf.appendLine(DashboardChrome.titleRule("Status", width: width))
        buf.appendLine(boxRow("", width: width))

        let manifestOverride = manifest.projects[project.projectID]?.tierOverride
        let pulseTier = pulse?.projectTiers?[project.projectID]
        let tierLabel: String
        if let override = manifestOverride {
            tierLabel = "\(override.rawValue) (override)"
        } else if let auto = pulseTier {
            tierLabel = "\(auto.rawValue) (auto)"
        } else {
            tierLabel = "unknown"
        }
        buf.appendLine(boxRow("  Tier:          \(tierLabel)", width: width))

        if let score = pulse?.statistics.weightedScores?[project.projectID] {
            let scoreStr = score.formatted(.number.precision(.fractionLength(3)))
            buf.appendLine(boxRow("  Quality Score: \(scoreStr)", width: width))
        } else {
            buf.appendLine(boxRow("  Quality Score: N/A", width: width))
        }

        if let trajectories = pulse?.projectTrajectories,
           let traj = trajectories.first(where: { $0.projectID == project.projectID }) {
            let arrow = traj.slope >= 0 ? "\u{2191}" : "\u{2193}"
            let slopeStr = abs(traj.slope).formatted(.number.precision(.fractionLength(3)))
            let r2Str = traj.rSquared.formatted(.number.precision(.fractionLength(2)))
            buf.appendLine(boxRow("  Trajectory:    \(traj.direction.rawValue) \(arrow) slope=\(slopeStr) r\u{00B2}=\(r2Str)", width: width))
            buf.appendLine(boxRow("  Validity:      \(traj.validity.rawValue) (\(traj.sampleSize) samples)", width: width))
            if traj.inflectionDetected {
                buf.appendLine(boxRow("  Inflection:    detected", width: width))
            }
        } else {
            buf.appendLine(boxRow("  Trajectory:    insufficient data", width: width))
        }

        buf.appendLine(boxRow("", width: width))

        buf.appendLine(DashboardChrome.sectionRule(width: width))
        buf.appendLine(boxRow("  Override Tier:", width: width))
        buf.appendLine(boxRow("", width: width))

        let allTiers = ProjectTier.allCases
        for (idx, tierCase) in allTiers.enumerated() {
            let isCurrent = (manifestOverride ?? pulseTier) == tierCase
            let isPickerSelected = state.tierPickerActive && idx == state.tierPickerIndex

            var label = "  "
            if isPickerSelected {
                label += ANSICodes.reverse + " \(tierCase.rawValue) " + ANSICodes.reset
            } else if isCurrent {
                label += ANSICodes.bold + "[\(tierCase.rawValue)]" + ANSICodes.reset
            } else {
                label += " \(tierCase.rawValue) "
            }
            buf.appendLine(boxRow(label, width: width))
        }

        buf.appendLine(boxRow("", width: width))
        if state.tierPickerActive {
            buf.appendLine(boxRow(ANSICodes.dim + "  \u{2191}\u{2193} Select  Enter Confirm  Esc Cancel" + ANSICodes.reset, width: width))
        } else {
            buf.appendLine(boxRow(ANSICodes.dim + "  Enter to edit tier override" + ANSICodes.reset, width: width))
        }
        buf.appendLine(boxRow("", width: width))
    }

    // MARK: - Helpers

    private static func boxRow(_ content: String, width: Int) -> String {
        DashboardChrome.contentRow(content, width: width)
    }

    private static func formatPercent(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return "\(pct)%"
    }
}
