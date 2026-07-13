// CorpusTrendChartView.swift
// IJSDashboardUI
//
// The corpus pass-rate trend as a native editorial line chart (BusinessMath-UI's
// EditorialChartView, house style), replacing the hand-rolled SwiftGUIKit sparkline.
// Each daily snapshot becomes a (Period.day, pass-rate%) point; `.line` shows the
// actual percentage (not a rebased index), which is what a pass-rate metric wants.

#if canImport(SwiftUI)
import SwiftUI
import CorpusKit
import BusinessMath
import BusinessMathUI
import BusinessMathAdapters

struct CorpusTrendChartView: View {
    let snapshots: [DailySnapshot]

    var body: some View {
        EditorialChartView(spec: makeSpec())
    }

    /// Builds the editorial line-chart spec, thinning the daily x-axis labels so a
    /// month of dates doesn't crush the axis.
    func makeSpec() -> ChartSpec {
        let series = TimeSeries(
            periods: snapshots.map { Period.day($0.date) },
            values: snapshots.map(CorpusTrend.passRatePercent)
        )
        var spec = ChartSpec.line(
            from: [LabeledSeries("Pass Rate", series)],
            title: "Corpus Pass Rate",
            subtitle: "Daily · last \(snapshots.count) days",
            theme: .house
        )
        spec.periods = CorpusTrend.thinnedLabels(spec.periods)
        return spec
    }
}
#endif
