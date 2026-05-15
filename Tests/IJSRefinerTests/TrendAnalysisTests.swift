import Testing
import Foundation
@testable import IJSRefiner
import IJSSensor

@Suite("TrendAnalysis")
struct TrendAnalysisTests {

    @Test("compute() golden path with 30 values produces valid analysis")
    func computeGoldenPath() {
        let values: [Double] = [0.72, 0.81, 0.93, 0.78, 0.85, 0.91, 0.74, 0.88, 0.82, 0.79,
                                0.90, 0.76, 0.87, 0.83, 0.94, 0.71, 0.80, 0.86, 0.92, 0.77,
                                0.84, 0.89, 0.73, 0.95, 0.75, 0.88, 0.81, 0.90, 0.79, 0.86]
        let result = TrendAnalysis.compute(metric: "passRate", values: values)
        #expect(result?.metric == "passRate")
        #expect(result?.sampleSize == 30)
        #expect(result?.validity == .valid)
        #expect(result?.dailyValues == values)
        if let r = result {
            #expect(r.ci90Low <= r.mean)
            #expect(r.ci90High >= r.mean)
            #expect(r.ci95Low <= r.ci90Low)
            #expect(r.ci95High >= r.ci90High)
        }
    }

    @Test("compute() with 15 values returns preliminary validity")
    func computePreliminary() {
        let values: [Double] = [0.72, 0.81, 0.93, 0.78, 0.85, 0.91, 0.74, 0.88, 0.82, 0.79,
                                0.90, 0.76, 0.87, 0.83, 0.94]
        let result = TrendAnalysis.compute(metric: "passRate", values: values)
        #expect(result?.metric == "passRate")
        #expect(result?.validity == .preliminary)
        #expect(result?.sampleSize == 15)
    }

    @Test("compute() with 2 values returns nil")
    func computeTooFew() {
        let result = TrendAnalysis.compute(metric: "passRate", values: [0.8, 0.9])
        #expect(result == nil)
    }

    @Test("compute() with exactly 3 values returns preliminary")
    func computeExactlyThree() {
        let result = TrendAnalysis.compute(metric: "passRate", values: [0.8, 0.9, 0.85])
        #expect(result?.metric == "passRate")
        #expect(result?.validity == .preliminary)
        #expect(result?.sampleSize == 3)
    }

    @Test("compute() with exactly 30 values returns valid")
    func computeExactlyThirty() {
        let values = Array(repeating: 0.85, count: 30)
        let result = TrendAnalysis.compute(metric: "passRate", values: values)
        #expect(result?.sampleSize == 30)
        #expect(result?.validity == .valid)
    }

    @Test("CI bounds match known distribution")
    func ciBoundsKnown() {
        let values = Array(repeating: 0.5, count: 30)
        let result = TrendAnalysis.compute(metric: "overrideRate", values: values)
        #expect(result?.metric == "overrideRate")
        #expect(abs((result?.mean ?? 0) - 0.5) < 0.001)
        #expect(abs((result?.ci90Low ?? 0) - 0.5) < 0.001)
        #expect(abs((result?.ci90High ?? 0) - 0.5) < 0.001)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let trend = TrendAnalysis(
            metric: "passRate",
            mean: 0.87,
            standardDeviation: 0.08,
            ci90Low: 0.74,
            ci90High: 1.0,
            ci95Low: 0.71,
            ci95High: 1.0,
            sampleSize: 90,
            validity: .valid,
            dailyValues: [0.85, 0.90, 0.83]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(trend)
        let decoded = try decoder.decode(TrendAnalysis.self, from: data)
        #expect(decoded == trend)
    }

    @Test("Metric name preserved through compute")
    func metricNamePreserved() {
        let result = TrendAnalysis.compute(metric: "calibrationRate", values: [0.1, 0.2, 0.15])
        #expect(result?.metric == "calibrationRate")
    }
}
