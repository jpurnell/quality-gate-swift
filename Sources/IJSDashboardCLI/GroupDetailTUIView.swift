import Foundation
import IJSAggregator
import IJSDashboardCore
import CorpusKit
import SwiftCLIKit

/// Renders the group detail view: group summary, member table, group trend, and
/// a derived group-level status block.
public enum GroupDetailTUIView: Sendable {

    /// Produces a formatted string for the group detail view.
    public static func render(
        groupID: String,
        memberProjects: [ProjectSummary],
        groupSnapshots: [DailySnapshot]?,
        pulse: InstitutionalPulse?,
        state: DashboardState,
        width: Int,
        manifest: CorpusManifest = CorpusManifest()
    ) -> String {
        var buf = ScreenBuffer(width: width)

        buf.appendLine(DashboardChrome.titleRule(" \(groupID) ", width: width))
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

        // Member table (sorted by projectID to match the input handler's ordering).
        let sorted = memberProjects.sorted { $0.projectID < $1.projectID }
        let nameWidth = min(max(width - 44, 12), 30)

        buf.appendLine(DashboardChrome.sectionRule(width: width))
        buf.appendLine(boxRow(memberHeaderRow(nameWidth: nameWidth), width: width))
        buf.appendLine(DashboardChrome.sectionRule(width: width))

        for (idx, project) in sorted.enumerated() {
            let isSelected = idx == state.selectedGroupMemberIndex
            renderMemberRow(
                into: &buf,
                project: project,
                pulse: pulse,
                nameWidth: nameWidth,
                selected: isSelected,
                width: width
            )
        }
        buf.appendLine(boxRow("", width: width))

        // Group trend + derived group-level status block.
        buf.appendLine(DashboardChrome.sectionRule(width: width))
        renderGroupTrend(into: &buf, snapshots: groupSnapshots, width: width)
        renderGroupStatus(
            into: &buf,
            groupID: groupID,
            memberProjects: sorted,
            aggregatePassRate: aggregatePassRate,
            groupSnapshots: groupSnapshots,
            pulse: pulse,
            manifest: manifest,
            width: width
        )
        buf.appendLine(boxRow("", width: width))

        buf.appendLine(DashboardChrome.sectionRule(width: width))

        let helpLine = ANSICodes.dim + "  \u{2191}/\u{2193} Select  \u{2192}/Enter Open  \u{2190} Back  q Quit" + ANSICodes.reset
        buf.appendLine(helpLine)

        return buf.raw
    }

    // MARK: - Member Table

    private static func memberHeaderRow(nameWidth: Int) -> String {
        // Four leading columns align the header's "Project" with member names,
        // which are prefixed by a two-space indent plus the status glyph + space.
        "    " + ljust("Project", nameWidth)
            + " " + ljust("St", 2)
            + " " + rjust("Pass", 5)
            + " " + rjust("Runs", 5)
            + " " + rjust("Ovr", 4)
            + " " + "Trajectory"
    }

    private static func renderMemberRow(
        into buf: inout ScreenBuffer,
        project: ProjectSummary,
        pulse: InstitutionalPulse?,
        nameWidth: Int,
        selected: Bool,
        width: Int
    ) {
        let passed = project.latestPassed
        // Middle-elide like the portfolio list so both the head and the
        // identity-bearing suffix survive in tight columns (HarborKit -> Ha…Kit).
        let namePad = ANSIStringMetrics.elideMiddle(project.projectID, to: nameWidth)
            .padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        let stPlain = ljust(passed ? "ok" : "!!", 2)
        let passTxt = rjust(formatPercent(project.passRate), 5)
        let runsTxt = rjust("\(project.runCount)", 5)
        let ovrTxt = rjust("\(project.totalOverrides)", 4)
        let traj = trajectoryCell(for: project.projectID, pulse: pulse)

        if selected {
            let plain = "  " + (passed ? "\u{2713}" : "\u{2717}") + " " + namePad
                + " " + stPlain + " " + passTxt + " " + runsTxt + " " + ovrTxt + " " + traj.plain
            buf.appendLine(boxRow(ANSICodes.reverse + plain + ANSICodes.reset, width: width))
        } else {
            let glyphColor = passed ? ANSICodes.fg(.green) : ANSICodes.fg(.red)
            let glyph = glyphColor + (passed ? "\u{2713}" : "\u{2717}") + ANSICodes.reset
            let st = glyphColor + stPlain + ANSICodes.reset
            let colored = "  " + glyph + " " + namePad
                + " " + st + " " + passTxt + " " + runsTxt + " " + ovrTxt + " " + traj.colored
            buf.appendLine(boxRow(colored, width: width))
        }
    }

    /// Builds the trajectory cell for a member: the direction word + arrow, plus a
    /// `z<score>` suffix when the member has a significant anomaly. Returns both a
    /// plain form (for the reverse-video selected row) and a colored form.
    private static func trajectoryCell(for projectID: String, pulse: InstitutionalPulse?) -> (plain: String, colored: String) {
        var plain: String
        var arrow: String?
        var arrowColor = ANSICodes.dim
        if let traj = pulse?.projectTrajectories?.first(where: { $0.projectID == projectID }) {
            switch traj.direction {
            case .improving: arrow = "\u{2191}"; arrowColor = ANSICodes.fg(.green)
            case .declining: arrow = "\u{2193}"; arrowColor = ANSICodes.fg(.red)
            case .stable: arrow = "\u{2192}"; arrowColor = ANSICodes.dim
            case .insufficient: arrow = "\u{00B7}"; arrowColor = ANSICodes.dim
            }
            plain = "\(traj.direction.rawValue) \(arrow ?? "")"
        } else {
            plain = "\u{2014}"
        }
        // The z-score is appended independently: a member can have a significant
        // anomaly without a computed trajectory.
        if let z = topAnomalyZScore(for: projectID, pulse: pulse) {
            let zStr = abs(z).formatted(.number.precision(.fractionLength(1)))
            plain += " z\(zStr)"
        }
        let colored: String
        if let arrow {
            colored = plain.replacingOccurrences(of: arrow, with: arrowColor + arrow + ANSICodes.reset)
        } else {
            colored = ANSICodes.dim + plain + ANSICodes.reset
        }
        return (plain, colored)
    }

    /// The largest-magnitude significant (|z| ≥ 2) anomaly z-score for a project.
    private static func topAnomalyZScore(for projectID: String, pulse: InstitutionalPulse?) -> Double? {
        guard let anomalies = pulse?.statistics.anomalies else { return nil }
        let scored = anomalies
            .filter { $0.scope == projectID && abs($0.zScore) >= 2 }
            .max { abs($0.zScore) < abs($1.zScore) }
        return scored?.zScore
    }

    // MARK: - Group Trend + Status

    private static func renderGroupTrend(into buf: inout ScreenBuffer, snapshots: [DailySnapshot]?, width: Int) {
        if let snapshots, !snapshots.isEmpty {
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
    }

    private static func renderGroupStatus(
        into buf: inout ScreenBuffer,
        groupID: String,
        memberProjects: [ProjectSummary],
        aggregatePassRate: Double,
        groupSnapshots: [DailySnapshot]?,
        pulse: InstitutionalPulse?,
        manifest: CorpusManifest,
        width: Int
    ) {
        // Nothing to derive without either snapshots or a pulse.
        let hasSnapshots = !(groupSnapshots?.isEmpty ?? true)
        guard hasSnapshots || pulse != nil else { return }

        buf.appendLine(boxRow("", width: width))

        let memberIDs = memberProjects.map(\.projectID)
        var tiers: [String: ProjectTier] = [:]
        for id in memberIDs {
            if let override = manifest.projects[id]?.tierOverride {
                tiers[id] = override
            } else if let auto = pulse?.projectTiers?[id] {
                tiers[id] = auto
            }
        }
        if let tier = GroupInsights.inferredTier(memberIDs: memberIDs, tiers: tiers) {
            buf.appendLine(boxRow("  Tier:          \(tier.rawValue) (inferred from members)", width: width))
        }

        let score = GroupInsights.qualityScore(
            memberIDs: memberIDs,
            aggregatePassRate: aggregatePassRate,
            weightedScores: pulse?.statistics.weightedScores
        )
        let scoreStr = score.formatted(.number.precision(.fractionLength(3)))
        buf.appendLine(boxRow("  Quality Score: \(scoreStr)", width: width))

        let traj = GroupInsights.groupTrajectory(groupID: groupID, snapshots: groupSnapshots ?? [])
        let arrow = traj.slope >= 0 ? "\u{2191}" : "\u{2193}"
        let slopeStr = abs(traj.slope).formatted(.number.precision(.fractionLength(3)))
        let r2Str = traj.rSquared.formatted(.number.precision(.fractionLength(2)))
        buf.appendLine(boxRow("  Trajectory:    \(traj.direction.rawValue) \(arrow) slope=\(slopeStr) r\u{00B2}=\(r2Str)", width: width))
        buf.appendLine(boxRow("  Validity:      \(traj.validity.rawValue) (\(traj.sampleSize) samples)", width: width))
    }

    // MARK: - Helpers

    private static func ljust(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - s.count)
    }

    private static func rjust(_ s: String, _ width: Int) -> String {
        s.count >= width ? String(s.prefix(width)) : String(repeating: " ", count: width - s.count) + s
    }

    private static func boxRow(_ content: String, width: Int) -> String {
        DashboardChrome.contentRow(content, width: width)
    }

    private static func formatPercent(_ value: Double) -> String {
        let pct = Int((value * 100).rounded())
        return "\(pct)%"
    }
}
