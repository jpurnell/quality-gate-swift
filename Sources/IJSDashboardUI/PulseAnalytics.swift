// PulseAnalytics.swift
// IJSDashboardUI
//
// Pure formatting for the pulse-derived analytical sections (Tiers, Trajectories,
// Groups) — free of SwiftUI and the charting libraries so they're unit-testable.
// Each helper takes plain values; the scene does the trivial extraction from the
// pulse types.

import Foundation
import CorpusKit

enum PulseAnalytics {

    /// "44 active · 4 baseline · 1 firstContact · 4 dormant" — tier counts,
    /// best-first, omitting empties. Nil when there are none.
    static func tierLine(_ tiers: [ProjectTier]) -> String? {
        guard !tiers.isEmpty else { return nil }
        var counts: [ProjectTier: Int] = [:]
        for tier in tiers { counts[tier, default: 0] += 1 }
        let parts = ProjectTier.allCases.sorted(by: >).compactMap { tier -> String? in
            let count = counts[tier] ?? 0
            return count > 0 ? "\(count) \(tier.rawValue)" : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "↑ 6 improving · → 42 stable · ↓ 4 declining" — trajectory direction counts.
    static func directionLine(_ directions: [TrajectoryDirection]) -> String? {
        guard !directions.isEmpty else { return nil }
        var counts: [TrajectoryDirection: Int] = [:]
        for direction in directions { counts[direction, default: 0] += 1 }
        let order: [(TrajectoryDirection, String)] = [(.improving, "↑"), (.stable, "→"), (.declining, "↓")]
        let parts = order.compactMap { direction, arrow -> String? in
            let count = counts[direction] ?? 0
            return count > 0 ? "\(arrow) \(count) \(direction.rawValue)" : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The `count` projects with the steepest (absolute) slope, formatted
    /// "ProjectID ↑0.014" / "↓0.013". Flat (zero-slope) movers are excluded.
    static func topMovers(_ movers: [(id: String, slope: Double)], count: Int = 3) -> [String] {
        movers
            .filter { abs($0.slope) > 0 }
            .sorted { abs($0.slope) > abs($1.slope) }
            .prefix(count)
            .map { mover in
                let arrow = mover.slope >= 0 ? "↑" : "↓"
                let magnitude = (abs(mover.slope) * 1000).rounded() / 1000
                return "\(mover.id) \(arrow)\(magnitude)"
            }
    }

    /// A pass rate as a 0–100 percentage, division-guarded.
    static func passRatePercent(passed: Int, total: Int) -> Double {
        total > 0 ? Double(passed) / Double(total) * 100 : 0
    }

    /// "BusinessMath: 31% (26 runs)".
    static func groupText(name: String, passRate: Double, runs: Int) -> String {
        "\(name): \(Int(passRate.rounded()))% (\(runs) runs)"
    }
}
