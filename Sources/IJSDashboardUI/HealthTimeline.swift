// HealthTimeline.swift
// IJSDashboardUI
//
// Pure helpers for the projects table's health-timeline column — the per-project
// recent daily pass rates rendered as a small heatmap. Free of SwiftUI so the
// bucketing and recency logic are unit-testable; the view maps levels to colors.

import Foundation

enum HealthTimeline {

    /// A health bucket for one day's pass rate, matching the terminal dashboard's
    /// thresholds (green ≥90%, yellow ≥75%, orange ≥60%, red below).
    enum Level: Equatable {
        case good, ok, warn, bad
    }

    /// Buckets a 0…1 pass rate.
    static func level(_ rate: Double) -> Level {
        if rate >= 0.9 { return .good }
        if rate >= 0.75 { return .ok }
        if rate >= 0.6 { return .warn }
        return .bad
    }

    /// The mean of the most recent `count` values — the sort key for the column.
    static func recentMean(_ values: [Double], count: Int = 10) -> Double {
        let recent = Array(values.suffix(count))
        let n = recent.count
        guard n > 0 else { return 0 }
        return recent.reduce(0, +) / Double(n)
    }
}
