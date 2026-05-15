import Foundation

/// Aggregated metrics with statistical benchmarking for a time window.
///
/// Contains both raw counts and trend analyses. All trend analyses carry
/// validity classifications so consumers know which results to trust.
public struct PulseStatistics: Sendable, Codable, Equatable {
    /// Total number of gate runs in the window.
    public let totalGateRuns: Int
    /// Gate runs that passed all checks.
    public let passedRuns: Int
    /// Gate runs with at least one failure.
    public let failedRuns: Int
    /// Total overrides recorded.
    public let totalOverrides: Int
    /// Total calibrations recorded.
    public let totalCalibrations: Int
    /// Overrides by risk tier.
    public let overridesByRiskTier: [RiskTier: Int]
    /// Failures by checker ID.
    public let failuresByChecker: [String: Int]
    /// Root cause adjective distribution from calibrations.
    public let rootCauseDistribution: [String: Int]
    /// Failed 5-Step stage distribution from calibrations.
    public let failedStepDistribution: [FiveStepStage: Int]
    /// Mean consistency score (nil if no runs scored).
    public let meanConsistencyScore: Double?
    /// Corpus-wide trend analyses for key metrics.
    public let corpusTrends: [TrendAnalysis]
    /// Per-project trend analyses, keyed by project ID.
    public let projectTrends: [String: [TrendAnalysis]]
    /// Statistical anomalies detected in this window.
    public let anomalies: [StatisticalAnomaly]
    /// Corpus-wide daily snapshots for the window.
    public let corpusSnapshots: [DailySnapshot]
    /// Per-project daily snapshots, keyed by project ID.
    public let projectSnapshots: [String: [DailySnapshot]]

    /// Pass rate as a percentage (0.0-100.0).
    public var passRate: Double {
        guard totalGateRuns > 0 else { return 0.0 }
        return Double(passedRuns) / Double(totalGateRuns) * 100.0
    }

    /// Override rate per gate run.
    public var overrideRate: Double {
        guard totalGateRuns > 0 else { return 0.0 }
        return Double(totalOverrides) / Double(totalGateRuns)
    }

    /// Creates new pulse statistics.
    public init(
        totalGateRuns: Int,
        passedRuns: Int,
        failedRuns: Int,
        totalOverrides: Int,
        totalCalibrations: Int,
        overridesByRiskTier: [RiskTier: Int],
        failuresByChecker: [String: Int],
        rootCauseDistribution: [String: Int],
        failedStepDistribution: [FiveStepStage: Int],
        meanConsistencyScore: Double?,
        corpusTrends: [TrendAnalysis],
        projectTrends: [String: [TrendAnalysis]],
        anomalies: [StatisticalAnomaly],
        corpusSnapshots: [DailySnapshot],
        projectSnapshots: [String: [DailySnapshot]]
    ) {
        self.totalGateRuns = totalGateRuns
        self.passedRuns = passedRuns
        self.failedRuns = failedRuns
        self.totalOverrides = totalOverrides
        self.totalCalibrations = totalCalibrations
        self.overridesByRiskTier = overridesByRiskTier
        self.failuresByChecker = failuresByChecker
        self.rootCauseDistribution = rootCauseDistribution
        self.failedStepDistribution = failedStepDistribution
        self.meanConsistencyScore = meanConsistencyScore
        self.corpusTrends = corpusTrends
        self.projectTrends = projectTrends
        self.anomalies = anomalies
        self.corpusSnapshots = corpusSnapshots
        self.projectSnapshots = projectSnapshots
    }
}
