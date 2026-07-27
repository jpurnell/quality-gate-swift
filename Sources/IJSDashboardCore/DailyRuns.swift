import Foundation
import IJSAggregator
import IJSSensor
import QualityGateTypes

/// Collapses a project's runs to one authoritative assessment per UTC day.
///
/// A project can record several runs on the same day for the *same* commit —
/// a scheduled run, then a local re-run after a fix. For per-day surfaces
/// (trend charts, the health sparkline) those are iterations of one day's
/// assessment, not separate ones. This mirrors the pulse's
/// `PulseRefiner.filterMetadataForScoring`, so every per-day surface agrees on
/// "one assessment per project per day."
///
/// Note: this is intentionally *not* used for ``ProjectSummary``'s historical
/// `passRate` / `checkerPassRates`, which count every full run as a data point
/// by design, nor for the composite latest-status logic, which honors targeted
/// `--check` refreshes.
public enum DailyRuns {

    /// The authoritative run for each UTC day, ascending by timestamp.
    ///
    /// Per day, the latest full standard run wins; if a day has no full standard
    /// run, its latest run overall is used so the day is never dropped.
    ///
    /// - Parameter runs: All of a project's runs, in any order.
    /// - Returns: One run per UTC day, sorted ascending by timestamp.
    public static func authoritativePerDay(_ runs: [TimestampedRun]) -> [TimestampedRun] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        let grouped = Dictionary(grouping: runs) { run -> Date in
            let components = calendar.dateComponents(
                [.year, .month, .day], from: run.metadata.timestamp)
            return calendar.date(from: components) ?? run.metadata.timestamp
        }

        return grouped
            .compactMap { _, dayRuns in authoritative(of: dayRuns) }
            .sorted { $0.metadata.timestamp < $1.metadata.timestamp }
    }

    /// The single authoritative run within one day's runs: the latest full
    /// standard run, or — when the day has none — the day's latest run overall.
    private static func authoritative(of dayRuns: [TimestampedRun]) -> TimestampedRun? {
        let fullStandard = dayRuns.filter {
            $0.metadata.runScope == .full && $0.metadata.gateMode == .standard
        }
        let pool = fullStandard.isEmpty ? dayRuns : fullStandard
        return pool.max { $0.metadata.timestamp < $1.metadata.timestamp }
    }
}
