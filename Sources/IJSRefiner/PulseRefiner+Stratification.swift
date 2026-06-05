import Foundation
import IJSSensor
import IJSAggregator

extension PulseRefiner {
    /// Classifies each project into a tier based on run recency and volume.
    func classifyProjects(
        projectSnapshots: [String: [DailySnapshot]],
        windowEnd: Date
    ) -> [String: ProjectTier] {
        var tiers: [String: ProjectTier] = [:]
        let calendar = Calendar.current

        for (projectID, snapshots) in projectSnapshots {
            let runCount = snapshots.reduce(0) { $0 + $1.gateRuns }
            let lastRunDate = snapshots.last?.date
            let daysSinceLastRun: Int
            if let lastDate = lastRunDate {
                daysSinceLastRun = calendar.dateComponents([.day], from: lastDate, to: windowEnd).day ?? 999
            } else {
                daysSinceLastRun = 999
            }
            tiers[projectID] = ProjectTier.classify(
                runCountInWindow: runCount,
                daysSinceLastRun: daysSinceLastRun
            )
        }
        return tiers
    }

    /// Minimum number of checker results for a run to be considered a full suite run.
    static let minimumCheckerCount = 5

    /// Filters per-project metadata to exclude partial runs and deduplicate to one run per day.
    ///
    /// Partial runs (fewer than ``minimumCheckerCount`` checkers) are single-checker debug
    /// invocations that would score 0.0 and distort the weighted average. When multiple
    /// full-suite runs exist on the same calendar day, only the latest is kept — earlier
    /// runs represent iteration, not separate assessments.
    func filterMetadataForScoring(
        _ projectMetadata: [String: [CheckResultMetadata]]
    ) -> [String: [CheckResultMetadata]] {
        var utcCalendar = Calendar(identifier: .iso8601)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        var filtered: [String: [CheckResultMetadata]] = [:]
        for (projectID, metadata) in projectMetadata {
            let fullRuns = metadata.filter { $0.results.count >= Self.minimumCheckerCount }

            let byDay = Dictionary(grouping: fullRuns) { meta -> DateComponents in
                utcCalendar.dateComponents([.year, .month, .day], from: meta.timestamp)
            }
            let deduped = byDay.compactMap { (_, dayRuns) -> CheckResultMetadata? in
                dayRuns.max(by: { $0.timestamp < $1.timestamp })
            }.sorted(by: { $0.timestamp < $1.timestamp })

            if !deduped.isEmpty {
                filtered[projectID] = deduped
            }
        }
        return filtered
    }

    /// Computes weighted quality scores for each project from its metadata.
    func computeWeightedScores(
        projectMetadata: [String: [CheckResultMetadata]]
    ) -> [String: Double] {
        var scores: [String: Double] = [:]
        for (projectID, metadata) in projectMetadata {
            let runScores = metadata.map { meta -> Double in
                let checkerResults = meta.results.map { result in
                    (checkerID: result.checkerId, passed: result.status == .passed)
                }
                return SeverityWeight.weightedScore(checkerResults: checkerResults)
            }
            guard !runScores.isEmpty else { continue }
            scores[projectID] = runScores.reduce(0, +) / Double(runScores.count) // fp-safety:disable guarded by isEmpty
        }
        return scores
    }

    /// Builds group-level daily snapshots by pooling member project snapshots.
    func computeGroupSnapshots(
        projectSnapshots: [String: [DailySnapshot]],
        groups: [String: [String]]
    ) -> [String: [DailySnapshot]] {
        var result: [String: [DailySnapshot]] = [:]

        for (groupID, memberIDs) in groups {
            var dateSnapshots: [Date: [DailySnapshot]] = [:]
            for memberID in memberIDs {
                guard let snapshots = projectSnapshots[memberID] else { continue }
                for snap in snapshots {
                    dateSnapshots[snap.date, default: []].append(snap)
                }
            }

            let groupSnaps: [DailySnapshot] = dateSnapshots.compactMap { (date, snaps) in
                let totalRuns = snaps.reduce(0) { $0 + $1.gateRuns }
                let totalPassed = snaps.reduce(0) { $0 + $1.passedRuns }
                let totalFailed = snaps.reduce(0) { $0 + $1.failedRuns }
                let totalOverrides = snaps.reduce(0) { $0 + $1.overrides }
                let totalCalibrations = snaps.reduce(0) { $0 + $1.calibrations }

                var mergedFailures: [String: Int] = [:]
                for snap in snaps {
                    for (checker, count) in snap.failuresByChecker {
                        mergedFailures[checker, default: 0] += count
                    }
                }

                var mergedOverrides: [RiskTier: Int] = [:]
                for snap in snaps {
                    for (tier, count) in snap.overridesByRiskTier {
                        mergedOverrides[tier, default: 0] += count
                    }
                }

                return DailySnapshot(
                    date: date,
                    scope: groupID,
                    gateRuns: totalRuns,
                    passedRuns: totalPassed,
                    failedRuns: totalFailed,
                    overrides: totalOverrides,
                    calibrations: totalCalibrations,
                    failuresByChecker: mergedFailures,
                    overridesByRiskTier: mergedOverrides
                )
            }.sorted { $0.date < $1.date }

            result[groupID] = groupSnaps
        }

        return result
    }
}
