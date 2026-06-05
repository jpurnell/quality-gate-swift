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
    /// Complexity trend analyses (nil if no complexity data in corpus).
    public let complexityTrends: [ComplexityTrend]?
    /// Severity-weighted scores per project, keyed by project ID.
    public let weightedScores: [String: Double]?
    /// Gated anomaly assessments combining anomaly + validity + tier context.
    public let gatedAnomalies: [AnomalyGate]?

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

    private enum CodingKeys: String, CodingKey {
        case totalGateRuns, passedRuns, failedRuns, totalOverrides, totalCalibrations
        case overridesByRiskTier, failuresByChecker
        case rootCauseDistribution, failedStepDistribution
        case meanConsistencyScore
        case corpusTrends, projectTrends, anomalies
        case corpusSnapshots, projectSnapshots
        case complexityTrends
        case weightedScores, gatedAnomalies
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
        projectSnapshots: [String: [DailySnapshot]],
        complexityTrends: [ComplexityTrend]? = nil,
        weightedScores: [String: Double]? = nil,
        gatedAnomalies: [AnomalyGate]? = nil
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
        self.complexityTrends = complexityTrends
        self.weightedScores = weightedScores
        self.gatedAnomalies = gatedAnomalies
    }

    /// Decodes pulse statistics, tolerating missing optional fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalGateRuns = try container.decode(Int.self, forKey: .totalGateRuns)
        passedRuns = try container.decode(Int.self, forKey: .passedRuns)
        failedRuns = try container.decode(Int.self, forKey: .failedRuns)
        totalOverrides = try container.decode(Int.self, forKey: .totalOverrides)
        totalCalibrations = try container.decode(Int.self, forKey: .totalCalibrations)
        overridesByRiskTier = try container.decode([RiskTier: Int].self, forKey: .overridesByRiskTier)
        failuresByChecker = try container.decode([String: Int].self, forKey: .failuresByChecker)
        rootCauseDistribution = try container.decode([String: Int].self, forKey: .rootCauseDistribution)
        failedStepDistribution = try container.decode([FiveStepStage: Int].self, forKey: .failedStepDistribution)
        meanConsistencyScore = try container.decodeIfPresent(Double.self, forKey: .meanConsistencyScore)
        corpusTrends = try container.decode([TrendAnalysis].self, forKey: .corpusTrends)
        projectTrends = try container.decode([String: [TrendAnalysis]].self, forKey: .projectTrends)
        anomalies = try container.decode([StatisticalAnomaly].self, forKey: .anomalies)
        corpusSnapshots = try container.decode([DailySnapshot].self, forKey: .corpusSnapshots)
        projectSnapshots = try container.decode([String: [DailySnapshot]].self, forKey: .projectSnapshots)
        complexityTrends = try container.decodeIfPresent([ComplexityTrend].self, forKey: .complexityTrends)
        weightedScores = try container.decodeIfPresent([String: Double].self, forKey: .weightedScores)
        gatedAnomalies = try container.decodeIfPresent([AnomalyGate].self, forKey: .gatedAnomalies)
    }

    /// Encodes all statistics fields, omitting nil optional properties.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalGateRuns, forKey: .totalGateRuns)
        try container.encode(passedRuns, forKey: .passedRuns)
        try container.encode(failedRuns, forKey: .failedRuns)
        try container.encode(totalOverrides, forKey: .totalOverrides)
        try container.encode(totalCalibrations, forKey: .totalCalibrations)
        try container.encode(overridesByRiskTier, forKey: .overridesByRiskTier)
        try container.encode(failuresByChecker, forKey: .failuresByChecker)
        try container.encode(rootCauseDistribution, forKey: .rootCauseDistribution)
        try container.encode(failedStepDistribution, forKey: .failedStepDistribution)
        try container.encodeIfPresent(meanConsistencyScore, forKey: .meanConsistencyScore)
        try container.encode(corpusTrends, forKey: .corpusTrends)
        try container.encode(projectTrends, forKey: .projectTrends)
        try container.encode(anomalies, forKey: .anomalies)
        try container.encode(corpusSnapshots, forKey: .corpusSnapshots)
        try container.encode(projectSnapshots, forKey: .projectSnapshots)
        try container.encodeIfPresent(complexityTrends, forKey: .complexityTrends)
        try container.encodeIfPresent(weightedScores, forKey: .weightedScores)
        try container.encodeIfPresent(gatedAnomalies, forKey: .gatedAnomalies)
    }
}
