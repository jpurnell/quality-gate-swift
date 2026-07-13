// CorpusTrend.swift
// IJSDashboardUI
//
// Pure helpers for the corpus-trend chart — deliberately free of SwiftUI and the
// BusinessMath charting libraries so they're unit-testable. (Referencing the
// chart View from a headless test bundle traps when the charting libs
// initialize; keeping this logic separate lets the tests run.)

import Foundation
import CorpusKit

enum CorpusTrend {

    /// A daily snapshot's pass rate as a 0–100 percentage, division-guarded.
    static func passRatePercent(_ snapshot: DailySnapshot) -> Double {
        snapshot.gateRuns > 0 ? Double(snapshot.passedRuns) / Double(snapshot.gateRuns) * 100 : 0
    }
}
