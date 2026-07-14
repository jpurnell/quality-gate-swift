// ProjectTrendChartView.swift
// IJSDashboardUI
//
// A single project's daily pass-rate trend as a native editorial line chart —
// the same BusinessMath-UI EditorialChartView (house style) the overview uses
// for the corpus trend, so the drill-down matches the portfolio page.

#if canImport(SwiftUI)
import SwiftUI
import IJSDashboardCore
import BusinessMath
import BusinessMathUI
import BusinessMathAdapters

struct ProjectTrendChartView: View {
    let points: [TrendPoint]

    var body: some View {
        EditorialChartView(spec: makeSpec())
    }

    /// Builds the editorial line-chart spec: each daily trend point becomes a
    /// (Period.day, pass-rate %) sample, with natively thinned x-axis labels.
    func makeSpec() -> ChartSpec {
        let series = TimeSeries(
            periods: points.map { Period.day($0.date) },
            values: points.map { $0.value * 100 }
        )
        var spec = ChartSpec.line(
            from: [LabeledSeries("Pass Rate", series)],
            title: "Pass Rate",
            subtitle: "Daily · last \(points.count) days",
            theme: .house
        )
        spec.xLabels = .auto
        return spec
    }
}
#endif
