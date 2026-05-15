import Testing
import Foundation
@testable import IJSRefiner
import IJSSensor

@Suite("PulseStatistics")
struct PulseStatisticsTests {

    private func makeStats(
        totalGateRuns: Int = 47,
        passedRuns: Int = 41,
        failedRuns: Int = 6,
        totalOverrides: Int = 3
    ) -> PulseStatistics {
        PulseStatistics(
            totalGateRuns: totalGateRuns,
            passedRuns: passedRuns,
            failedRuns: failedRuns,
            totalOverrides: totalOverrides,
            totalCalibrations: 3,
            overridesByRiskTier: [.operational: 1, .safety: 2],
            failuresByChecker: ["ConcurrencyAuditor": 3, "SafetyAuditor": 2],
            rootCauseDistribution: ["contextually naive": 2, "expedient": 1],
            failedStepDistribution: [.diagnosis: 2, .design: 1],
            meanConsistencyScore: 0.82,
            corpusTrends: [],
            projectTrends: [:],
            anomalies: [],
            corpusSnapshots: [],
            projectSnapshots: [:]
        )
    }

    @Test("Golden path: all fields populated")
    func goldenPath() {
        let stats = makeStats()
        #expect(stats.totalGateRuns == 47)
        #expect(stats.passedRuns == 41)
        #expect(stats.failedRuns == 6)
        #expect(stats.totalOverrides == 3)
        #expect(stats.totalCalibrations == 3)
        #expect(stats.failuresByChecker["ConcurrencyAuditor"] == 3)
        #expect(stats.rootCauseDistribution["contextually naive"] == 2)
        #expect(stats.failedStepDistribution[.diagnosis] == 2)
        #expect(abs((stats.meanConsistencyScore ?? 0) - 0.82) < 1e-6)
    }

    @Test("passRate computed correctly as percentage")
    func passRate() {
        let stats = makeStats(totalGateRuns: 100, passedRuns: 87)
        #expect(abs(stats.passRate - 87.0) < 0.001)
    }

    @Test("overrideRate computed correctly")
    func overrideRate() {
        let stats = makeStats(totalGateRuns: 47, totalOverrides: 3)
        #expect(abs(stats.overrideRate - (3.0 / 47.0)) < 0.001)
    }

    @Test("Zero gate runs returns 0 for rates")
    func zeroGateRuns() {
        let stats = makeStats(totalGateRuns: 0, passedRuns: 0, failedRuns: 0, totalOverrides: 0)
        #expect(abs(stats.passRate - 0.0) < 1e-6)
        #expect(abs(stats.overrideRate - 0.0) < 1e-6)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let stats = makeStats()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(stats)
        let decoded = try decoder.decode(PulseStatistics.self, from: data)
        #expect(decoded == stats)
    }

    @Test("Empty trends and anomalies")
    func emptyTrendsAndAnomalies() {
        let stats = makeStats()
        #expect(stats.corpusTrends.isEmpty)
        #expect(stats.projectTrends.isEmpty)
        #expect(stats.anomalies.isEmpty)
    }

    @Test("Mixed validity trends in statistics")
    func mixedValidityTrends() {
        let validTrend = TrendAnalysis(
            metric: "passRate", mean: 0.87, standardDeviation: 0.08,
            ci90Low: 0.74, ci90High: 1.0, ci95Low: 0.71, ci95High: 1.0,
            sampleSize: 90, validity: .valid, dailyValues: []
        )
        let prelimTrend = TrendAnalysis(
            metric: "passRate", mean: 0.85, standardDeviation: 0.12,
            ci90Low: 0.62, ci90High: 1.0, ci95Low: 0.55, ci95High: 1.0,
            sampleSize: 12, validity: .preliminary, dailyValues: []
        )
        let stats = PulseStatistics(
            totalGateRuns: 47, passedRuns: 41, failedRuns: 6,
            totalOverrides: 3, totalCalibrations: 3,
            overridesByRiskTier: [:], failuresByChecker: [:],
            rootCauseDistribution: [:], failedStepDistribution: [:],
            meanConsistencyScore: nil,
            corpusTrends: [validTrend],
            projectTrends: ["new-project": [prelimTrend]],
            anomalies: [], corpusSnapshots: [], projectSnapshots: [:]
        )
        #expect(stats.corpusTrends.first?.validity == .valid)
        #expect(stats.projectTrends["new-project"]?.first?.validity == .preliminary)
    }
}
