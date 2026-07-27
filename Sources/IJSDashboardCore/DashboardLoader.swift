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
import QualityGateTypes

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

        // Health timeline: the last 14 days' checker pass rate (passing ÷ total),
        // one point per day from that day's authoritative run (see ``DailyRuns``)
        // so a rerun-heavy day can't crowd the window or blend its own runs.
        let health = allRuns.mapValues { runs -> [Double] in
            DailyRuns.authoritativePerDay(runs)
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

    /// The newest content-modification date anywhere under a corpus directory —
    /// a cheap change signature for pollers (e.g. the GUI's auto-refresh) that
    /// want to reload only when the corpus actually changed, rather than
    /// re-parsing every run on a fixed interval.
    ///
    /// - Parameter path: The corpus directory to scan.
    /// - Returns: The maximum file modification time under `path`, or nil when
    ///   the directory can't be enumerated (callers then reload unconditionally).
    public static func corpusSignature(at path: String) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: keys
        ) else { return nil }
        var newest: Date?
        for case let fileURL as URL in enumerator {
            // silent: a file whose mtime can't be read simply doesn't advance the signature
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate else { continue }
            if let current = newest {
                if modified > current { newest = modified }
            } else {
                newest = modified
            }
        }
        return newest
    }

    /// Each checker's results from its most recent *standard-mode* run — the
    /// composite view that mirrors ``ProjectSummary/latestCheckerPassed``.
    ///
    /// Advisory surveys are excluded (they downgrade gating findings to notes,
    /// which would masquerade as acknowledgeable inbox items), and a targeted
    /// `--check` subset run only refreshes the checkers it actually covered.
    /// Shared by the inbox so it can never read a partial or advisory run as a
    /// project's whole current state.
    public static func latestStandardResults(of runs: [TimestampedRun]) -> [CheckResult] {
        let standard = runs
            .filter { $0.metadata.gateMode == .standard }
            .sorted { $0.metadata.timestamp < $1.metadata.timestamp }
        var latestForChecker: [String: CheckResult] = [:]
        for run in standard {              // ascending — later runs overwrite earlier
            for result in run.metadata.results {
                latestForChecker[result.checkerId] = result
            }
        }
        return Array(latestForChecker.values)
    }

    /// The advisory findings for a project, composed from each checker's latest
    /// standard-mode run, mapped to the surface-agnostic ``InboxFinding``.
    /// Shared by ``load(corpusPath:week:)`` and the CLI's `dashboard --native`
    /// so both compute the same inbox.
    public static func inboxFindings(fromLatestOf runs: [TimestampedRun]) -> [InboxFinding] {
        FindingsInbox.items(fromResults: latestStandardResults(of: runs)).map { item in
            InboxFinding(ruleID: item.ruleId ?? "(no rule id)", message: item.message,
                         filePath: item.filePath, lineNumber: item.lineNumber,
                         acknowledgeable: item.isAcknowledgeable)
        }
    }
}
