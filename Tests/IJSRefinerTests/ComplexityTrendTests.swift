import Foundation
import Testing
@testable import IJSRefiner
@testable import IJSSensor
@testable import IJSAggregator

@Suite("Complexity Trend Tests")
struct ComplexityTrendTests {

    @Test("Builds complexity snapshots from reports grouped by date")
    func buildComplexitySnapshots() async {
        let refiner = PulseRefiner(writer: TelemetryWriter())
        let reports = [
            makeReport(day: "2026-05-14", median: 4, p90: 10, max: 18, patterns: 2, aboveThreshold: 1),
            makeReport(day: "2026-05-15", median: 5, p90: 11, max: 20, patterns: 3, aboveThreshold: 2),
            makeReport(day: "2026-05-16", median: 6, p90: 12, max: 22, patterns: 4, aboveThreshold: 2),
        ]

        let snapshots = await refiner.buildComplexitySnapshots(from: reports, scope: "test-project")
        #expect(snapshots.count == 3)
        #expect(snapshots[0].date == "2026-05-14")
        #expect(snapshots[0].medianCognitive == 4)
        #expect(snapshots[2].medianCognitive == 6)
        #expect(snapshots[2].totalPatterns == 4)
    }

    @Test("Analyzes complexity trends from snapshots")
    func analyzeComplexityTrends() async throws {
        let refiner = PulseRefiner(writer: TelemetryWriter())
        let snapshots = (0..<7).map { i in
            ComplexitySnapshot(
                date: "2026-05-\(10 + i)",
                scope: "test",
                medianCognitive: 5 + i,
                p90Cognitive: 12 + i,
                maxCognitive: 20 + i,
                totalPatterns: 2 + i,
                functionsAboveThreshold: 1,
                dominantBigO: "O(n)"
            )
        }

        let trends = await refiner.analyzeComplexityTrends(from: snapshots)
        #expect(trends.count >= 2)
        let medianTrend = try #require(trends.first { $0.metricName == "medianCognitive" })
        #expect(medianTrend.trend.sampleSize == 7)
    }

    @Test("Detects emerging and resolved patterns between windows")
    func detectPatternChanges() async {
        let refiner = PulseRefiner(writer: TelemetryWriter())

        let baseline = [
            makeReport(day: "2026-05-01", patterns: ["containsInFilter", "sortInLoop"]),
            makeReport(day: "2026-05-02", patterns: ["containsInFilter"]),
        ]
        let window = [
            makeReport(day: "2026-05-14", patterns: ["containsInFilter", "quadraticStringConcat"]),
            makeReport(day: "2026-05-15", patterns: ["quadraticStringConcat"]),
        ]

        let (emerging, resolved) = await refiner.detectPatternChanges(
            baselineReports: baseline,
            windowReports: window
        )
        #expect(emerging.contains("quadraticStringConcat"))
        #expect(resolved.contains("sortInLoop"))
        #expect(!emerging.contains("containsInFilter"))
    }

    @Test("Empty reports produce empty trends")
    func emptyReports() async {
        let refiner = PulseRefiner(writer: TelemetryWriter())
        let snapshots = await refiner.buildComplexitySnapshots(from: [], scope: "test")
        #expect(snapshots.isEmpty)
        let trends = await refiner.analyzeComplexityTrends(from: [])
        #expect(trends.isEmpty)
    }

    // MARK: - Helpers

    private func makeReport(
        day: String,
        median: Int = 5,
        p90: Int = 12,
        max: Int = 20,
        patterns: Int = 2,
        aboveThreshold: Int = 1
    ) -> ComplexityReport {
        ComplexityReport(
            projectID: "test-project",
            timestamp: dateFromDay(day),
            modules: [],
            summary: ComplexitySummary(
                totalFunctions: 50,
                medianCognitive: median,
                p90Cognitive: p90,
                maxCognitive: max,
                complexityDistribution: ["O(1)": 30, "O(n)": 15, "O(n²)": 5],
                totalPatterns: patterns,
                patternBreakdown: [:],
                functionsAboveThreshold: aboveThreshold
            )
        )
    }

    private func makeReport(day: String, patterns: [String]) -> ComplexityReport {
        var breakdown: [String: Int] = [:]
        for p in patterns { breakdown[p, default: 0] += 1 }
        return ComplexityReport(
            projectID: "test-project",
            timestamp: dateFromDay(day),
            modules: [],
            summary: ComplexitySummary(
                totalFunctions: 10,
                medianCognitive: 5,
                p90Cognitive: 12,
                maxCognitive: 20,
                complexityDistribution: [:],
                totalPatterns: patterns.count,
                patternBreakdown: breakdown,
                functionsAboveThreshold: 0
            )
        )
    }

    private func dateFromDay(_ day: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: day) ?? Date()
    }
}
