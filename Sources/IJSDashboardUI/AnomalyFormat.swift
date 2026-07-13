// AnomalyFormat.swift
// IJSDashboardUI
//
// Formatting for the projects table's anomaly column — the per-project
// statistical anomaly (metric, z-score, direction) from the pulse. Free of
// SwiftUI/charting so the formatting is unit-testable; matches the terminal
// dashboard's anomaly cell.

import Foundation
import CorpusKit

enum AnomalyFormat {

    /// The resolved anomaly cell for one project.
    struct Cell: Equatable {
        let text: String        // e.g. "pass z2.4↑"
        let magnitude: Double   // |z-score|, for sorting
        let isGood: Bool        // reads as an improvement, not a regression
    }

    /// A short metric label matching the terminal dashboard.
    static func metricShort(_ metric: String) -> String {
        switch metric {
        case "passRate": "pass"
        case "failureRate": "fail"
        case "overrideRate": "ovrd"
        case "calibrationRate": "cal"
        default: String(metric.prefix(4))
        }
    }

    /// "pass z2.4↑" — short metric + |z| (one decimal) + direction arrow.
    static func cellText(metric: String, zScore: Double, isUp: Bool) -> String {
        let z = (abs(zScore) * 10).rounded() / 10
        return "\(metricShort(metric)) z\(z)\(isUp ? "↑" : "↓")"
    }

    /// An anomaly is "good" when pass rate rose, or a bad metric fell.
    static func isGood(metric: String, isUp: Bool) -> Bool {
        metric == "passRate" ? isUp : !isUp
    }

    /// The most-severe anomaly per project scope, as a display cell. Severity
    /// breaks ties toward the larger |z-score|, matching the terminal dashboard.
    static func lookup(_ anomalies: [StatisticalAnomaly]) -> [String: Cell] {
        Dictionary(grouping: anomalies, by: \.scope).compactMapValues { items in
            guard let top = items.max(by: { lhs, rhs in
                lhs.severity != rhs.severity ? lhs.severity < rhs.severity : abs(lhs.zScore) < abs(rhs.zScore)
            }) else { return nil }
            let isUp = top.direction == .positive
            return Cell(
                text: cellText(metric: top.metric, zScore: top.zScore, isUp: isUp),
                magnitude: abs(top.zScore),
                isGood: isGood(metric: top.metric, isUp: isUp)
            )
        }
    }
}
