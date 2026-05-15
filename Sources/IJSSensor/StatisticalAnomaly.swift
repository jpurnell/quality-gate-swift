import Foundation

/// Whether an anomaly represents improvement or degradation.
public enum AnomalyDirection: String, Sendable, Codable {
    /// Better than expected (e.g., higher pass rate, lower override rate).
    case positive
    /// Worse than expected (e.g., lower pass rate, higher override rate).
    case negative
}

/// Severity of a statistical anomaly, aligned with z-score thresholds.
public enum AnomalySeverity: String, Sendable, Codable, Comparable {
    /// 90% CI breach (1.645-2.0 standard deviations).
    case notable
    /// 95% CI breach (2.0-3.0 standard deviations).
    case significant
    /// Beyond 3 standard deviations.
    case extreme

    /// Compares severity levels.
    public static func < (lhs: AnomalySeverity, rhs: AnomalySeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .notable: 0
        case .significant: 1
        case .extreme: 2
        }
    }
}

/// A metric value that falls outside the expected confidence interval.
///
/// Anomalies detected against a preliminary baseline (< 30 observations)
/// carry the baseline's validity classification so consumers can
/// discount them appropriately.
public struct StatisticalAnomaly: Sendable, Codable, Equatable {
    /// Which metric triggered the anomaly.
    public let metric: String
    /// The observed value on the anomalous day.
    public let observedValue: Double
    /// The expected value (historical mean).
    public let expectedValue: Double
    /// Z-score: how many standard deviations from the mean.
    public let zScore: Double
    /// Severity classification.
    public let severity: AnomalySeverity
    /// The date of the anomalous observation.
    public let date: Date
    /// The scope: project ID or "corpus".
    public let scope: String
    /// Whether this is a positive anomaly (better than expected) or negative.
    public let direction: AnomalyDirection
    /// Statistical reliability of the baseline used for detection.
    public let baselineValidity: StatisticalValidity

    /// Creates a new statistical anomaly.
    public init(
        metric: String,
        observedValue: Double,
        expectedValue: Double,
        zScore: Double,
        severity: AnomalySeverity,
        date: Date,
        scope: String,
        direction: AnomalyDirection,
        baselineValidity: StatisticalValidity
    ) {
        self.metric = metric
        self.observedValue = observedValue
        self.expectedValue = expectedValue
        self.zScore = zScore
        self.severity = severity
        self.date = date
        self.scope = scope
        self.direction = direction
        self.baselineValidity = baselineValidity
    }
}
