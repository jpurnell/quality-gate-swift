import Foundation
import IJSAggregator
import QualityGateTypes

/// Aggregated statistics for a single project's quality gate history.
public struct ProjectSummary: Sendable {
    /// The project identifier.
    public let projectID: String
    /// Fraction of runs where all checkers passed (0.0–1.0).
    public let passRate: Double
    /// Whether the most recent run passed all checkers.
    public let latestPassed: Bool
    /// The checker with the lowest pass rate, if any.
    public let worstChecker: String?
    /// Per-checker pass rates across all runs.
    public let checkerPassRates: [String: Double]
    /// Whether each checker passed in the most recent run.
    public let latestCheckerPassed: [String: Bool]
    /// Total number of overrides across all runs.
    public let totalOverrides: Int
    /// Number of runs analyzed.
    public let runCount: Int
    /// The lifecycle state of the project.
    public let lifecycle: ProjectLifecycle

    /// Computes a summary from a series of timestamped runs.
    ///
    /// - Parameters:
    ///   - projectID: The project identifier.
    ///   - runs: The timestamped runs to analyze.
    ///   - lifecycle: The project's lifecycle state (defaults to ``ProjectLifecycle/active``).
    /// - Returns: An aggregated summary of the project's quality gate history.
    public static func compute(
        projectID: String,
        from runs: [TimestampedRun],
        lifecycle: ProjectLifecycle = .active
    ) -> ProjectSummary {
        guard !runs.isEmpty else {
            return ProjectSummary(
                projectID: projectID,
                passRate: 0,
                latestPassed: false,
                worstChecker: nil,
                checkerPassRates: [:],
                latestCheckerPassed: [:],
                totalOverrides: 0,
                runCount: 0,
                lifecycle: lifecycle
            )
        }

        let sortedRuns = runs.sorted { $0.metadata.timestamp < $1.metadata.timestamp }

        let passingCount = sortedRuns.filter { run in
            run.metadata.results.allSatisfy { $0.status.isPassing }
        }.count
        let runTotal = Double(sortedRuns.count)
        let passRate = runTotal > 0 ? Double(passingCount) / runTotal : 0

        let latestRun = sortedRuns.last
        let latestPassed = latestRun.map { run in
            run.metadata.results.allSatisfy { $0.status.isPassing }
        } ?? false

        var checkerPassCount: [String: Int] = [:]
        var checkerTotalCount: [String: Int] = [:]
        for run in sortedRuns {
            for result in run.metadata.results {
                checkerTotalCount[result.checkerId, default: 0] += 1
                if result.status.isPassing {
                    checkerPassCount[result.checkerId, default: 0] += 1
                }
            }
        }

        var checkerPassRates: [String: Double] = [:]
        for (checkerId, total) in checkerTotalCount {
            guard total > 0 else { continue }
            checkerPassRates[checkerId] = Double(checkerPassCount[checkerId, default: 0]) / Double(total)
        }

        let worstChecker = checkerPassRates.min { $0.value < $1.value }?.key

        var latestCheckerPassed: [String: Bool] = [:]
        for run in sortedRuns.reversed() {
            for result in run.metadata.results {
                if latestCheckerPassed[result.checkerId] == nil {
                    latestCheckerPassed[result.checkerId] = result.status.isPassing
                }
            }
        }

        let totalOverrides = sortedRuns.reduce(0) { $0 + $1.metadata.overrides.count }

        return ProjectSummary(
            projectID: projectID,
            passRate: passRate,
            latestPassed: latestPassed,
            worstChecker: worstChecker,
            checkerPassRates: checkerPassRates,
            latestCheckerPassed: latestCheckerPassed,
            totalOverrides: totalOverrides,
            runCount: sortedRuns.count,
            lifecycle: lifecycle
        )
    }
}
