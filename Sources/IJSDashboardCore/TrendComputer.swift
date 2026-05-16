import Foundation
import QualityGateTypes

/// A single data point in a time-series trend.
public struct TrendPoint: Sendable {
    /// The date this point represents.
    public let date: Date
    /// The computed metric value for this date.
    public let value: Double

    /// Creates a trend data point.
    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// Computes time-series trends from quality gate run history.
public enum TrendComputer: Sendable {
    /// Computes daily pass rate as a time series.
    ///
    /// Groups runs by calendar day (UTC), then for each day computes
    /// the fraction of runs where all checkers passed.
    public static func dailyPassRate(from runs: [TimestampedRun]) -> [TrendPoint] {
        let grouped = groupByDay(runs)
        return grouped.map { date, dayRuns in
            let passing = dayRuns.filter { run in
                run.metadata.results.allSatisfy { $0.status.isPassing }
            }.count
            let dayTotal = Double(dayRuns.count)
            let rate = dayTotal > 0 ? Double(passing) / dayTotal : 0
            return TrendPoint(date: date, value: rate)
        }.sorted { $0.date < $1.date }
    }

    /// Computes daily median check duration as a time series.
    ///
    /// Groups runs by calendar day (UTC), collects all individual
    /// checker durations for that day, and returns the median.
    public static func dailyMedianDuration(from runs: [TimestampedRun]) -> [TrendPoint] {
        let grouped = groupByDay(runs)
        return grouped.map { date, dayRuns in
            let allDurations = dayRuns.flatMap { run in
                run.metadata.results.map { durationToSeconds($0.duration) }
            }
            let median = computeMedian(allDurations)
            return TrendPoint(date: date, value: median)
        }.sorted { $0.date < $1.date }
    }

    private static func groupByDay(_ runs: [TimestampedRun]) -> [Date: [TimestampedRun]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        var groups: [Date: [TimestampedRun]] = [:]
        for run in runs {
            let components = calendar.dateComponents([.year, .month, .day], from: run.metadata.timestamp)
            guard let dayStart = calendar.date(from: components) else { continue }
            groups[dayStart, default: []].append(run)
        }
        return groups
    }

    private static func durationToSeconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    private static func computeMedian(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}
