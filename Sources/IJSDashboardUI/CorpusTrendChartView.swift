// CorpusTrendChartView.swift
// IJSDashboardUI
//
// The corpus pass-rate trend as a native editorial line chart (BusinessMath-UI's
// EditorialChartView, house style), replacing the hand-rolled SwiftGUIKit sparkline.
// Each daily snapshot becomes a (day, pass-rate%) point; `.line` shows the actual
// percentage (not a rebased index), which is what a pass-rate metric wants.

#if canImport(SwiftUI)
import SwiftUI
import CorpusKit
import BusinessMath
import BusinessMathUI
import BusinessMathAdapters

struct CorpusTrendChartView: View {
    let snapshots: [DailySnapshot]

    var body: some View {
        let series = TimeSeries(
            periods: snapshots.map { Period.day($0.date) },
            values: snapshots.map(Self.passRatePercent)
        )
        let spec = ChartSpec.line(
            from: [LabeledSeries("Pass Rate", series)],
            title: "Corpus Pass Rate",
            subtitle: "Daily · last \(snapshots.count) days",
            theme: .house
        )
        EditorialChartView(spec: spec)
    }

    /// A daily snapshot's pass rate as a 0–100 percentage, division-guarded.
    static func passRatePercent(_ snapshot: DailySnapshot) -> Double {
        snapshot.gateRuns > 0 ? Double(snapshot.passedRuns) / Double(snapshot.gateRuns) * 100 : 0
    }
}
#endif
