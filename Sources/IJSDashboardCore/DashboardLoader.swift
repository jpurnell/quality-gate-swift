// DashboardLoader.swift
// IJSDashboardCore
//
// Loads a corpus directory into the view-model data the dashboard needs
// (portfolio, projects, pulse, per-project health). Shared by the CLI's
// `dashboard --native` and the standalone SwiftUI app so both compute identically.

import Foundation
import IJSAggregator
import IJSSensor
import JudgmentWorkbench

/// One advisory finding from a project's latest run, ready for the drill-down
/// inbox. A surface-agnostic mirror of ``JudgmentWorkbench/InboxItem`` so the
/// dashboard UI layer needn't depend on JudgmentWorkbench.
public struct InboxFinding: Sendable, Identifiable, Equatable {
    /// The rule that produced the finding (or a placeholder when none was carried).
    public let ruleID: String
    /// The finding's human-readable message.
    public let message: String
    /// Absolute path of the flagged file.
    public let filePath: String
    /// 1-based flagged line number.
    public let lineNumber: Int
    /// Whether the rule has an in-place acknowledgment path.
    public let acknowledgeable: Bool

    /// A stable identity for lists and tables.
    public var id: String { "\(ruleID)|\(filePath)|\(lineNumber)" }

    /// The flagged file's last path component, for compact display.
    public var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    /// Creates an inbox finding.
    public init(ruleID: String, message: String, filePath: String,
                lineNumber: Int, acknowledgeable: Bool) {
        self.ruleID = ruleID
        self.message = message
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.acknowledgeable = acknowledgeable
    }
}

/// Everything the portfolio dashboard renders, loaded from a corpus.
public struct DashboardData: Sendable {
    /// The cross-project rollup.
    public let portfolio: PortfolioSummary
    /// The per-project summaries.
    public let projects: [ProjectSummary]
    /// The latest (or requested) institutional pulse, if any.
    public let pulse: InstitutionalPulse?
    /// Per-project recent per-run checker pass rates for the health timeline.
    public let health: [String: [Double]]
    /// Group memberships from the manifest (group ID → member project IDs).
    public let groups: [String: [String]]
    /// Per-project advisory findings from the latest run, for the drill-down inbox.
    public let inbox: [String: [InboxFinding]]
    /// Per-project daily pass-rate trend, for the drill-down trend chart.
    public let trends: [String: [TrendPoint]]

    /// Creates the dashboard's loaded data.
    public init(portfolio: PortfolioSummary, projects: [ProjectSummary],
                pulse: InstitutionalPulse?, health: [String: [Double]],
                groups: [String: [String]] = [:],
                inbox: [String: [InboxFinding]] = [:],
                trends: [String: [TrendPoint]] = [:]) {
        self.portfolio = portfolio
        self.projects = projects
        self.pulse = pulse
        self.health = health
        self.groups = groups
        self.inbox = inbox
        self.trends = trends
    }
}

/// Loads `DashboardData` from a corpus path.
public enum DashboardLoader {

    /// Reads the corpus, computes summaries, the latest pulse, and the health
    /// timeline. Pure over the filesystem — safe to call off the main actor.
    /// - Parameters:
    ///   - corpusPath: The IJS corpus directory.
    ///   - week: An optional pulse label; defaults to the latest pulse.
    public static func load(corpusPath: String, week: String? = nil) throws -> DashboardData {
        let reader = CorpusReader(corpusPath: corpusPath)
        let allRuns = try reader.loadAll()
        // silent: an absent/unreadable manifest is non-fatal — fall back to empty.
        let manifest = (try? reader.loadManifest()) ?? CorpusManifest()

        // silent: orientation reports are optional — their absence is non-fatal.
        let orientationCards = (try? reader.loadAllOrientationReports())
            .map { PortfolioOrientation.cards(from: $0, knownProjects: Set(allRuns.keys)) } ?? [:]

        let projects = allRuns
            .map { entry in
                ProjectSummary.compute(projectID: entry.key, from: entry.value,
                                       lifecycle: manifest.lifecycle(for: entry.key),
                                       orientation: orientationCards[entry.key])
            }
            .sorted { $0.projectID < $1.projectID }

        let portfolio = PortfolioSummary.compute(from: projects)
        let pulse = week.flatMap { reader.loadPulse(label: $0) } ?? reader.loadLatestPulse()

        // Health timeline: recent runs' checker pass rate (passing ÷ total per run).
        let health = allRuns.mapValues { runs -> [Double] in
            runs.sorted { $0.metadata.timestamp < $1.metadata.timestamp }
                .suffix(14)
                .map { run in
                    let results = run.metadata.results
                    let count = results.count
                    guard count > 0 else { return 0 }
                    return Double(results.filter { $0.status.isPassing }.count) / Double(count)
                }
        }

        // Inbox: advisory findings from each project's latest run (Phase 3a §7).
        let inbox = allRuns.mapValues { inboxFindings(fromLatestOf: $0) }

        // Per-project daily pass-rate trend for the drill-down chart.
        let trends = allRuns.mapValues { TrendComputer.dailyPassRate(from: $0) }

        return DashboardData(portfolio: portfolio, projects: projects, pulse: pulse,
                             health: health, groups: manifest.groups, inbox: inbox,
                             trends: trends)
    }

    /// The advisory findings from the most recent of `runs`, mapped to the
    /// surface-agnostic ``InboxFinding``. Shared by ``load(corpusPath:week:)``
    /// and the CLI's `dashboard --native` so both compute the same inbox.
    public static func inboxFindings(fromLatestOf runs: [TimestampedRun]) -> [InboxFinding] {
        guard let latest = runs.max(by: { $0.metadata.timestamp < $1.metadata.timestamp })
        else { return [] }
        return FindingsInbox.items(from: latest.metadata).map { item in
            InboxFinding(ruleID: item.ruleId ?? "(no rule id)", message: item.message,
                         filePath: item.filePath, lineNumber: item.lineNumber,
                         acknowledgeable: item.isAcknowledgeable)
        }
    }
}
