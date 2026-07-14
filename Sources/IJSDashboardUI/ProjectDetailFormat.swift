// ProjectDetailFormat.swift
// IJSDashboardUI
//
// Pure, charting-free formatting for the project drill-down: checker rows,
// tier / trajectory / score labels, and the baseline burn-down trail. Free of
// SwiftUI and the charting libraries so it stays unit-testable in a headless
// test bundle (matching PulseAnalytics / HealthTimeline / AnomalyFormat).

import Foundation
import IJSDashboardCore
import CorpusKit

/// Formatting helpers for ``ProjectDetailView``.
public enum ProjectDetailFormat {

    /// One checker's aggregate pass rate and latest-run status.
    public struct CheckerRow: Identifiable, Sendable, Equatable {
        /// The checker's identifier.
        public let name: String
        /// Fraction of runs this checker passed (0.0–1.0).
        public let passRate: Double
        /// Whether the checker passed in the most recent run.
        public let latestPassed: Bool
        /// Stable identity for tables.
        public var id: String { name }
        /// The pass rate as a whole percentage.
        public var passPercent: Int { Int((passRate * 100).rounded()) }

        /// Creates a checker row.
        public init(name: String, passRate: Double, latestPassed: Bool) {
            self.name = name
            self.passRate = passRate
            self.latestPassed = latestPassed
        }
    }

    /// The checker rows, worst pass rate first (ties broken by name) — matching
    /// the terminal detail's Checkers tab.
    public static func checkerRows(passRates: [String: Double],
                                   latestPassed: [String: Bool]) -> [CheckerRow] {
        passRates
            .map { CheckerRow(name: $0.key, passRate: $0.value,
                              latestPassed: latestPassed[$0.key] ?? false) }
            .sorted { lhs, rhs in
                lhs.passRate == rhs.passRate ? lhs.name < rhs.name : lhs.passRate < rhs.passRate
            }
    }

    /// A human-readable label for a project tier.
    public static func tierLabel(_ tier: ProjectTier) -> String {
        switch tier {
        case .dormant: "Dormant"
        case .atRisk: "At Risk"
        case .firstContact: "First Contact"
        case .baseline: "Baseline"
        case .active: "Active"
        }
    }

    /// A human-readable label for a trajectory direction.
    public static func trajectoryLabel(_ direction: TrajectoryDirection) -> String {
        switch direction {
        case .improving: "Improving"
        case .stable: "Stable"
        case .declining: "Declining"
        case .insufficient: "Insufficient data"
        }
    }

    /// An up/down/flat arrow for a slope.
    public static func slopeArrow(_ slope: Double) -> String {
        if slope > 0 { return "↑" }
        if slope < 0 { return "↓" }
        return "→"
    }

    /// The trend direction of a pass-rate series (earliest vs latest value).
    public static func trendDirection(_ series: [Double]) -> String {
        guard series.count >= 2, let first = series.first, let last = series.last else {
            return "Stable"
        }
        let delta = last - first
        if delta > 1e-6 { return "↑ Improving" }
        if delta < -1e-6 { return "↓ Declining" }
        return "Stable"
    }

    /// A quality score formatted to three places, or "N/A" when absent.
    public static func scoreText(_ score: Double?) -> String {
        guard let score else { return "N/A" }
        return score.formatted(.number.precision(.fractionLength(3)))
    }

    /// A double rendered with a fixed number of fraction digits — the safe
    /// (non-C-printf) equivalent of `String(format: "%.Nf", value)`.
    public static func fixed(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }

    /// The debt burn-down trail as "N → N → N" over the most recent snapshots.
    public static func burnDownTrail(_ snapshots: [BaselineSnapshot], limit: Int = 6) -> String {
        snapshots.suffix(limit).map { "\($0.baselined)" }.joined(separator: " → ")
    }
}
