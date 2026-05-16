import Foundation

/// Aggregated statistics across all projects in the corpus.
public struct PortfolioSummary: Sendable {
    /// Total number of projects in the portfolio.
    public let totalProjects: Int
    /// Number of projects whose latest run passed.
    public let passingProjects: Int
    /// Number of projects whose latest run failed.
    public let failingProjects: Int
    /// Checker IDs sorted by aggregate pass rate (worst first).
    public let worstCheckers: [String]

    /// Computes a portfolio summary from per-project summaries.
    public static func compute(from projects: [ProjectSummary]) -> PortfolioSummary {
        let passing = projects.filter(\.latestPassed).count

        var checkerPassCount: [String: Int] = [:]
        var checkerTotalCount: [String: Int] = [:]
        for project in projects {
            for (checkerId, rate) in project.checkerPassRates {
                checkerTotalCount[checkerId, default: 0] += 1
                if abs(rate - 1.0) < Double.ulpOfOne {
                    checkerPassCount[checkerId, default: 0] += 1
                }
            }
        }

        var aggregateRates: [String: Double] = [:]
        for (checkerId, total) in checkerTotalCount {
            guard total > 0 else { continue }
            aggregateRates[checkerId] = Double(checkerPassCount[checkerId, default: 0]) / Double(total)
        }

        let sorted = aggregateRates.sorted { $0.value < $1.value }.map(\.key)

        return PortfolioSummary(
            totalProjects: projects.count,
            passingProjects: passing,
            failingProjects: projects.count - passing,
            worstCheckers: sorted
        )
    }
}
