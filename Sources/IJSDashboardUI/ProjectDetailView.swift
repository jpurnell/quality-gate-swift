// ProjectDetailView.swift
// IJSDashboardUI
//
// The project drill-down: a tabbed detail screen (Summary / Checkers / Inbox)
// reached by selecting a project in the portfolio table. It renders from data
// already loaded into the dashboard — the project summary, the latest pulse, the
// health series, and the advisory inbox — so no extra corpus read is needed.
// This mirrors the terminal ProjectDetailTUIView, natively.

#if canImport(SwiftUI)
import SwiftUI
import IJSDashboardCore
import CorpusKit

/// A tabbed detail view for a single project.
public struct ProjectDetailView: View {

    /// The tabs, matching the terminal detail view.
    private enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case checkers = "Checkers"
        case inbox = "Inbox"
        var id: String { rawValue }
    }

    private let project: ProjectSummary
    private let pulse: InstitutionalPulse?
    private let health: [Double]
    private let inbox: [InboxFinding]

    @State private var tab: Tab = .summary

    /// Creates the detail view for one project.
    /// - Parameters:
    ///   - project: The project's aggregated summary.
    ///   - pulse: The latest institutional pulse, for tier/score/trajectory.
    ///   - health: The project's recent per-run pass-rate series, for the trend.
    ///   - inbox: Advisory findings from the project's latest run.
    public init(project: ProjectSummary, pulse: InstitutionalPulse?,
                health: [Double] = [], inbox: [InboxFinding] = []) {
        self.project = project
        self.pulse = pulse
        self.health = health
        self.inbox = inbox
    }

    /// The detail view body.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            .frame(maxWidth: 420)

            Divider().padding(.top, 12)

            switch tab {
            case .summary: ScrollView { summary.padding() }
            case .checkers: checkers
            case .inbox: inboxTable
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle(project.projectID)
    }

    // MARK: Summary

    private var trajectory: ProjectTrajectory? {
        pulse?.projectTrajectories?.first { $0.projectID == project.projectID }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusHeader
            metricsSection
            statusSection
            if let baseline = project.latestBaseline { baselineSection(baseline) }
            if let orientation = project.orientation { orientationSection(orientation) }
            trendSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(project.projectID).font(.title2.bold())
                Text(project.latestPassed ? "PASSING" : "FAILING")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(project.latestPassed ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .foregroundStyle(project.latestPassed ? Color.green : Color.red)
                    .clipShape(Capsule())
            }
            if let census = project.writerCensus, census.tripped {
                Label("Multi-writer (\(census.persons.joined(separator: ", "))) — Phase 3 controls required",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pass Rate").frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                Gauge(value: min(max(project.passRate, 0), 1)) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(project.latestPassed ? Color.green : Color.red)
                    .frame(maxWidth: 260)
                Text("\(Int((project.passRate * 100).rounded()))%").monospacedDigit()
            }
            metricRow("Runs", runsText)
            metricRow("Overrides", "\(project.totalOverrides)")
            if let worst = project.worstChecker { metricRow("Worst Checker", worst) }
        }
    }

    private var runsText: String {
        project.partialRunCount > 0
            ? "\(project.runCount) full (+\(project.partialRunCount) partial)"
            : "\(project.runCount)"
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Status").font(.headline)
            if let tier = pulse?.projectTiers?[project.projectID] {
                metricRow("Tier", ProjectDetailFormat.tierLabel(tier))
            }
            metricRow("Quality Score",
                      ProjectDetailFormat.scoreText(pulse?.statistics.weightedScores?[project.projectID]))
            if let traj = trajectory {
                metricRow("Trajectory", trajectoryText(traj))
            }
        }
    }

    private func trajectoryText(_ traj: ProjectTrajectory) -> String {
        let base = "\(ProjectDetailFormat.slopeArrow(traj.slope)) \(ProjectDetailFormat.trajectoryLabel(traj.direction)) "
            + "(slope \(ProjectDetailFormat.fixed(traj.slope, places: 3)), R² \(ProjectDetailFormat.fixed(traj.rSquared, places: 2)), n=\(traj.sampleSize))"
        return traj.inflectionDetected ? base + " · inflection" : base
    }

    @ViewBuilder
    private func baselineSection(_ baseline: BaselineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Baseline").font(.headline)
            metricRow("Debts", "\(baseline.baselined)")
            if baseline.expired > 0 {
                metricRow("Expired", "\(baseline.expired)")
            }
            if baseline.newFindings > 0 {
                metricRow("New Findings", "\(baseline.newFindings)")
            }
            let trail = ProjectDetailFormat.burnDownTrail(project.baselineBurnDown)
            if !trail.isEmpty { metricRow("Burn-down", trail) }
        }
    }

    @ViewBuilder
    private func orientationSection(_ card: ModuleOrientationCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Orientation").font(.headline)
            if let what = card.whatItDoes { metricRow("What it does", what) }
            metricRow("Role", card.role)
            if !card.dependsOn.isEmpty { metricRow("Built from", elided(card.dependsOn)) }
            if !card.reliedOnBy.isEmpty { metricRow("Relied on by", elided(card.reliedOnBy)) }
            if let why = card.why { metricRow("Why", why) }
        }
    }

    private func elided(_ items: [String], limit: Int = 6) -> String {
        guard items.count > limit else { return items.joined(separator: ", ") }
        return items.prefix(limit).joined(separator: ", ") + " (+\(items.count - limit) more)"
    }

    @ViewBuilder
    private var trendSection: some View {
        if health.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pass Rate Trend").font(.headline)
                Sparkline(values: health)
                    .frame(height: 44)
                    .frame(maxWidth: 360)
                Text("Direction: \(ProjectDetailFormat.trendDirection(health)) (\(health.count) runs)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Checkers

    @ViewBuilder
    private var checkers: some View {
        let rows = ProjectDetailFormat.checkerRows(passRates: project.checkerPassRates,
                                                   latestPassed: project.latestCheckerPassed)
        if rows.isEmpty {
            emptyState("No checker history for this project.")
        } else {
            CheckersDetailTable(rows: rows)
        }
    }

    // MARK: Inbox

    @ViewBuilder
    private var inboxTable: some View {
        if inbox.isEmpty {
            emptyState("Inbox zero — no advisory findings in the latest run.")
        } else {
            InboxTable(findings: inbox)
        }
    }

    // MARK: Shared bits

    @ViewBuilder
    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func emptyState(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A minimal line sparkline for a 0…1 series — no charting-library dependency.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let count = values.count
            Path { path in
                let divisor = CGFloat(count - 1)
                guard divisor > 0 else { return }
                let stepX = geo.size.width / divisor
                for (index, value) in values.enumerated() {
                    let clamped = min(max(value, 0), 1)
                    let x = CGFloat(index) * stepX
                    let y = geo.size.height * (1 - CGFloat(clamped))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }
}

/// The Checkers tab as a native sortable table.
private struct CheckersDetailTable: View {
    let rows: [ProjectDetailFormat.CheckerRow]
    @State private var sortOrder = [KeyPathComparator(\ProjectDetailFormat.CheckerRow.passRate)]

    var body: some View {
        Table(rows.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Checker", value: \.name) { Text($0.name).lineLimit(1).truncationMode(.middle) }
            TableColumn("Latest") { row in
                Text(row.latestPassed ? "✓" : "✗")
                    .foregroundStyle(row.latestPassed ? Color.green : Color.red)
            }
            TableColumn("Pass Rate", value: \.passRate) { row in
                HStack(spacing: 8) {
                    Gauge(value: min(max(row.passRate, 0), 1)) { EmptyView() }
                        .gaugeStyle(.linearCapacity)
                        .tint(row.passRate >= 0.9 ? Color.green : (row.passRate >= 0.6 ? Color.orange : Color.red))
                        .frame(maxWidth: 120)
                    Text("\(row.passPercent)%").monospacedDigit()
                }
            }
        }
    }
}

/// The Inbox tab as a native sortable table of advisory findings.
private struct InboxTable: View {
    let findings: [InboxFinding]
    @State private var sortOrder = [KeyPathComparator(\InboxFinding.ruleID)]

    var body: some View {
        Table(findings.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Rule", value: \.ruleID) { Text($0.ruleID).lineLimit(1).truncationMode(.middle) }
            TableColumn("File", value: \.fileName) { Text($0.fileName).lineLimit(1).truncationMode(.middle) }
            TableColumn("Line", value: \.lineNumber) { Text("\($0.lineNumber)").monospacedDigit() }
            TableColumn("Message", value: \.message) { Text($0.message).lineLimit(2) }
            TableColumn("Ack") { row in
                Text(row.acknowledgeable ? "✓" : "—")
                    .foregroundStyle(row.acknowledgeable ? Color.green : Color.secondary)
            }
        }
    }
}
#endif
