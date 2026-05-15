import Foundation
import BusinessMath
import IJSSensor

extension TrendAnalysis {
    /// Computes a TrendAnalysis from an array of daily metric values.
    ///
    /// Uses BusinessMath's `mean()` and `stdDev()` for descriptive statistics,
    /// and `confidenceInterval(ci:values:)` for bounds.
    ///
    /// - Returns: A TrendAnalysis, or nil if fewer than 3 data points.
    public static func compute(metric: String, values: [Double]) -> TrendAnalysis? {
        guard values.count >= 3 else { return nil }

        let mu = BusinessMath.mean(values)
        let sd = BusinessMath.stdDev(values)
        let ci90 = confidenceInterval(ci: 0.90, values: values)
        let ci95 = confidenceInterval(ci: 0.95, values: values)

        return TrendAnalysis(
            metric: metric,
            mean: mu,
            standardDeviation: sd,
            ci90Low: ci90.low,
            ci90High: ci90.high,
            ci95Low: ci95.low,
            ci95High: ci95.high,
            sampleSize: values.count,
            validity: StatisticalValidity.from(sampleSize: values.count),
            dailyValues: values
        )
    }
}
