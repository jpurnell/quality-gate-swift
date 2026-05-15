import Foundation

/// A single day's aggregated quality gate metrics for one project or the entire corpus.
///
/// DailySnapshots form the time series that TrendAnalysis operates on.
/// They are persisted to the corpus by TelemetryWriter for historical baseline computation.
public struct DailySnapshot: Sendable, Codable, Equatable {
    /// The date this snapshot covers.
    public let date: Date
    /// Project ID, or "corpus" for the corpus-wide aggregate.
    public let scope: String
    /// Total gate runs on this day.
    public let gateRuns: Int
    /// Gate runs that passed all checks.
    public let passedRuns: Int
    /// Gate runs with at least one failure.
    public let failedRuns: Int
    /// Total overrides recorded.
    public let overrides: Int
    /// Total calibrations (post-mortems) recorded.
    public let calibrations: Int
    /// Breakdown of failures by checker ID.
    public let failuresByChecker: [String: Int]
    /// Breakdown of overrides by risk tier.
    public let overridesByRiskTier: [RiskTier: Int]

    /// Pass rate as a fraction (0.0-1.0). Returns 0 if no gate runs.
    public var passRate: Double {
        guard gateRuns > 0 else { return 0.0 }
        return Double(passedRuns) / Double(gateRuns)
    }

    /// Overrides per gate run. Returns 0 if no gate runs.
    public var overrideRate: Double {
        guard gateRuns > 0 else { return 0.0 }
        return Double(overrides) / Double(gateRuns)
    }

    /// Calibrations per gate run. Returns 0 if no gate runs.
    public var calibrationRate: Double {
        guard gateRuns > 0 else { return 0.0 }
        return Double(calibrations) / Double(gateRuns)
    }

    /// Failure rate as a fraction (0.0-1.0). Returns 0 if no gate runs.
    public var failureRate: Double {
        guard gateRuns > 0 else { return 0.0 }
        return Double(failedRuns) / Double(gateRuns)
    }

    /// Creates a new daily snapshot.
    /// - Parameters:
    ///   - date: The date this snapshot covers.
    ///   - scope: Project ID or "corpus" for corpus-wide aggregate.
    ///   - gateRuns: Total gate runs on this day.
    ///   - passedRuns: Gate runs that passed all checks.
    ///   - failedRuns: Gate runs with at least one failure.
    ///   - overrides: Total overrides recorded.
    ///   - calibrations: Total calibrations recorded.
    ///   - failuresByChecker: Breakdown of failures by checker ID.
    ///   - overridesByRiskTier: Breakdown of overrides by risk tier.
    public init(
        date: Date,
        scope: String,
        gateRuns: Int,
        passedRuns: Int,
        failedRuns: Int,
        overrides: Int,
        calibrations: Int,
        failuresByChecker: [String: Int],
        overridesByRiskTier: [RiskTier: Int]
    ) {
        self.date = date
        self.scope = scope
        self.gateRuns = gateRuns
        self.passedRuns = passedRuns
        self.failedRuns = failedRuns
        self.overrides = overrides
        self.calibrations = calibrations
        self.failuresByChecker = failuresByChecker
        self.overridesByRiskTier = overridesByRiskTier
    }
}
