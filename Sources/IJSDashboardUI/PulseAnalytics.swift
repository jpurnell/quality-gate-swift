// PulseAnalytics.swift
// IJSDashboardUI
//
// Pure, testable computation for the pulse-derived analytical sections (Tiers,
// Trajectories, Groups, Worst Checkers) — free of SwiftUI and the charting
// libraries. Each helper takes plain values / IJSDashboardCore + CorpusKit types;
// the native views render the results as grids and tables.

import Foundation
import CorpusKit
import IJSDashboardCore

enum PulseAnalytics {

    /// Present tiers with their counts, best-first (active → dormant).
    static func tierCounts(_ tiers: [ProjectTier]) -> [(tier: ProjectTier, count: Int)] {
        guard !tiers.isEmpty else { return [] }
        var counts: [ProjectTier: Int] = [:]
        for tier in tiers { counts[tier, default: 0] += 1 }
        return ProjectTier.allCases.sorted(by: >).compactMap { tier in
            let count = counts[tier] ?? 0
            return count > 0 ? (tier, count) : nil
        }
    }

    /// Improving / stable / declining counts, in that fixed order (zeros included
    /// so the grid always shows all three headers).
    static func directionCounts(_ directions: [TrajectoryDirection]) -> [(direction: TrajectoryDirection, count: Int)] {
        var counts: [TrajectoryDirection: Int] = [:]
        for direction in directions { counts[direction, default: 0] += 1 }
        return [.improving, .stable, .declining].map { ($0, counts[$0] ?? 0) }
    }

    /// The `count` steepest movers by |slope|, as (project, "↑0.014", |slope|).
    /// Flat (zero-slope) movers are excluded.
    static func topMovers(_ movers: [(id: String, slope: Double)], count: Int = 5)
        -> [(id: String, trajectory: String, magnitude: Double)] {
        movers
            .filter { abs($0.slope) > 0 }
            .sorted { abs($0.slope) > abs($1.slope) }
            .prefix(count)
            .map { mover in
                let arrow = mover.slope >= 0 ? "↑" : "↓"
                let magnitude = (abs(mover.slope) * 1000).rounded() / 1000
                return (mover.id, "\(arrow)\(magnitude)", abs(mover.slope))
            }
    }

    /// A pass rate as a 0–100 percentage, division-guarded.
    static func passRatePercent(passed: Int, total: Int) -> Double {
        total > 0 ? Double(passed) / Double(total) * 100 : 0
    }

    /// Per-worst-checker stats: mean pass rate across projects (0–100) and total
    /// failure count from the pulse.
    static func worstCheckerStats(worst: [String], projects: [ProjectSummary], failuresByChecker: [String: Int])
        -> [(checker: String, passRate: Double, failures: Int)] {
        worst.map { checker in
            let rates = projects.compactMap { $0.checkerPassRates[checker] }
            let count = rates.count
            let mean = count > 0 ? rates.reduce(0, +) / Double(count) * 100 : 0
            return (checker, mean, failuresByChecker[checker] ?? 0)
        }
    }
}
