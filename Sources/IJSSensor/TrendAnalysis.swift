import Foundation

/// Time series analysis of a metric over a sequence of DailySnapshots.
///
/// The struct holds computed results. Use `TrendAnalysis.compute(metric:values:)`
/// from the IJSRefiner module to produce instances from raw data.
public struct TrendAnalysis: Sendable, Codable, Equatable {
    /// The metric being analyzed (e.g., "passRate", "overrideRate").
    public let metric: String
    /// Mean value across the time series.
    public let mean: Double
    /// Standard deviation of the time series.
    public let standardDeviation: Double
    /// 90% confidence interval lower bound.
    public let ci90Low: Double
    /// 90% confidence interval upper bound.
    public let ci90High: Double
    /// 95% confidence interval lower bound.
    public let ci95Low: Double
    /// 95% confidence interval upper bound.
    public let ci95High: Double
    /// Number of data points in the series.
    public let sampleSize: Int
    /// Statistical reliability of this analysis.
    public let validity: StatisticalValidity
    /// Daily values in chronological order.
    public let dailyValues: [Double]

    /// Creates a new trend analysis.
    public init(
        metric: String,
        mean: Double,
        standardDeviation: Double,
        ci90Low: Double,
        ci90High: Double,
        ci95Low: Double,
        ci95High: Double,
        sampleSize: Int,
        validity: StatisticalValidity,
        dailyValues: [Double]
    ) {
        self.metric = metric
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.ci90Low = ci90Low
        self.ci90High = ci90High
        self.ci95Low = ci95Low
        self.ci95High = ci95High
        self.sampleSize = sampleSize
        self.validity = validity
        self.dailyValues = dailyValues
    }
}
