// DashboardLoader.swift
// IJSDashboardCore
//
// Loads a corpus directory into the view-model data the dashboard needs
// (portfolio, projects, pulse, per-project health). Shared by the CLI's
// `dashboard --native` and the standalone SwiftUI app so both compute identically.

import Foundation
import IJSAggregator
import IJSSensor

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

    /// Creates the dashboard's loaded data.
    public init(portfolio: PortfolioSummary, projects: [ProjectSummary],
                pulse: InstitutionalPulse?, health: [String: [Double]],
                groups: [String: [String]] = [:]) {
        self.portfolio = portfolio
        self.projects = projects
        self.pulse = pulse
        self.health = health
        self.groups = groups
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

        let projects = allRuns
            .map { entry in
                ProjectSummary.compute(projectID: entry.key, from: entry.value,
                                       lifecycle: manifest.lifecycle(for: entry.key))
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

        return DashboardData(portfolio: portfolio, projects: projects, pulse: pulse,
                             health: health, groups: manifest.groups)
    }
}
