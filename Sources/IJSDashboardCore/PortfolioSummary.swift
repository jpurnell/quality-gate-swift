import Foundation
import IJSAggregator

/// Aggregated statistics across all projects in the corpus.
public struct PortfolioSummary: Sendable {
    /// Total number of active projects in the portfolio.
    public let totalProjects: Int
    /// Number of active projects whose latest run passed.
    public let passingProjects: Int
    /// Number of active projects whose latest run failed.
    public let failingProjects: Int
    /// Number of projects in the sunset lifecycle state.
    public let sunsetProjects: Int
    /// Checker IDs sorted by aggregate pass rate (worst first).
    public let worstCheckers: [String]

    /// Computes a portfolio summary from per-project summaries.
    ///
    /// Active and sunset projects are partitioned by their ``ProjectLifecycle`` state.
    /// Only active projects contribute to ``totalProjects``, ``passingProjects``,
    /// ``failingProjects``, and ``worstCheckers``.
    public static func compute(from projects: [ProjectSummary]) -> PortfolioSummary {
        let active = projects.filter { $0.lifecycle == .active }
        let sunsetCount = projects.filter { $0.lifecycle == .sunset }.count
        let passing = active.filter(\.latestPassed).count

        var checkerPassCount: [String: Int] = [:]
        var checkerTotalCount: [String: Int] = [:]
        for project in active {
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
            totalProjects: active.count,
            passingProjects: passing,
            failingProjects: active.count - passing,
            sunsetProjects: sunsetCount,
            worstCheckers: sorted
        )
    }
}
