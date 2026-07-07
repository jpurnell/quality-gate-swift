import Foundation
import IJSSensor

/// Derives group-level status from member data and daily snapshots.
///
/// The pulse pipeline computes tiers, weighted quality scores, and trajectories
/// per *project* but not per *group* — groups only carry `groupSnapshots`. These
/// pure helpers reconstruct comparable group-level figures on demand so the group
/// detail view can show a status block like a project's Status section.
public enum GroupInsights: Sendable {

    /// Computes a linear-regression trajectory over a group's daily pass rates.
    ///
    /// Reuses the same validity/direction thresholds as per-project trajectories
    /// by classifying with `StatisticalValidity.from(sampleSize:)` and
    /// `TrajectoryDirection.from(slope:sampleSize:)`, and returns a
    /// `ProjectTrajectory` keyed by `groupID` so existing trajectory rendering
    /// applies unchanged.
    ///
    /// - Parameters:
    ///   - groupID: Identifier used as the returned trajectory's `projectID`.
    ///   - snapshots: The group's daily snapshots (any order; sorted by date here).
    /// - Returns: A trajectory; `.insufficient` when there are fewer than two points.
    public static func groupTrajectory(groupID: String, snapshots: [DailySnapshot]) -> ProjectTrajectory {
        let sorted = snapshots.sorted { $0.date < $1.date }
        let n = sorted.count
        guard n >= 2 else {
            return ProjectTrajectory(
                projectID: groupID,
                slope: 0, intercept: 0, rSquared: 0,
                sampleSize: n,
                validity: .insufficient,
                direction: .insufficient
            )
        }

        let xs = (0..<n).map(Double.init)
        let ys = sorted.map(\.passRate)
        // n >= 2 here, but keep the divisor guard visible at the division site.
        let count = Double(n)
        let meanX = count > 0 ? xs.reduce(0, +) / count : 0
        let meanY = count > 0 ? ys.reduce(0, +) / count : 0

        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for i in 0..<n {
            let dx = xs[i] - meanX
            let dy = ys[i] - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }

        // x values are a fixed 0..<n ramp, so sxx > 0 for n >= 2; guard anyway.
        let slope = sxx > Double.ulpOfOne ? sxy / sxx : 0
        let intercept = meanY - slope * meanX
        let denom = sxx * syy
        let rSquared = denom > Double.ulpOfOne ? (sxy * sxy) / denom : 0

        return ProjectTrajectory(
            projectID: groupID,
            slope: slope,
            intercept: intercept,
            rSquared: rSquared,
            sampleSize: n,
            validity: StatisticalValidity.from(sampleSize: n),
            direction: TrajectoryDirection.from(slope: slope, sampleSize: n)
        )
    }

    /// A group's quality score: the mean of members' weighted scores when any are
    /// available, otherwise the aggregate pass rate.
    ///
    /// - Parameters:
    ///   - memberIDs: The group's member project IDs.
    ///   - aggregatePassRate: Fallback score (0…1) when no weighted scores exist.
    ///   - weightedScores: Per-project weighted scores from the pulse, if present.
    public static func qualityScore(
        memberIDs: [String],
        aggregatePassRate: Double,
        weightedScores: [String: Double]?
    ) -> Double {
        let scores = memberIDs.compactMap { weightedScores?[$0] }
        guard !scores.isEmpty else { return aggregatePassRate }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// The most common tier among a group's members, tie-broken deterministically
    /// toward the earliest `ProjectTier.allCases` entry; `nil` if none are known.
    ///
    /// - Parameters:
    ///   - memberIDs: The group's member project IDs.
    ///   - tiers: Resolved tier per member (manifest override ?? auto), if known.
    public static func inferredTier(memberIDs: [String], tiers: [String: ProjectTier]) -> ProjectTier? {
        var counts: [ProjectTier: Int] = [:]
        for id in memberIDs {
            if let tier = tiers[id] {
                counts[tier, default: 0] += 1
            }
        }
        guard !counts.isEmpty else { return nil }
        // Highest count wins; ties resolve toward the earliest tier in canonical order.
        return ProjectTier.allCases
            .filter { counts[$0] != nil }
            .max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
    }
}
