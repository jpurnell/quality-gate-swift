import Foundation
import Testing
@testable import IJSSensor

@Suite("ComplexityReport Tests")
struct ComplexityReportTests {

    // MARK: - ComplexitySnapshot

    @Test("ComplexitySnapshot stores daily complexity metrics")
    func snapshotBasicProperties() {
        let snapshot = ComplexitySnapshot(
            date: "2026-05-16",
            scope: "quality-gate-swift",
            medianCognitive: 5,
            p90Cognitive: 12,
            maxCognitive: 28,
            totalPatterns: 3,
            functionsAboveThreshold: 2,
            dominantBigO: "O(n)"
        )
        #expect(snapshot.date == "2026-05-16")
        #expect(snapshot.scope == "quality-gate-swift")
        #expect(snapshot.medianCognitive == 5)
        #expect(snapshot.p90Cognitive == 12)
        #expect(snapshot.maxCognitive == 28)
        #expect(snapshot.totalPatterns == 3)
        #expect(snapshot.functionsAboveThreshold == 2)
        #expect(snapshot.dominantBigO == "O(n)")
    }

    @Test("ComplexitySnapshot round-trips through JSON")
    func snapshotCodable() throws {
        let snapshot = ComplexitySnapshot(
            date: "2026-05-16",
            scope: "test-project",
            medianCognitive: 8,
            p90Cognitive: 15,
            maxCognitive: 22,
            totalPatterns: 5,
            functionsAboveThreshold: 3,
            dominantBigO: "O(n²)"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(ComplexitySnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    // MARK: - ComplexityReport

    @Test("ComplexityReport aggregates module data")
    func reportAggregation() {
        let report = ComplexityReport(
            projectID: "quality-gate-swift",
            timestamp: Date(timeIntervalSince1970: 1747400000),
            modules: [
                ModuleComplexityReport(
                    moduleName: "Core",
                    functionCount: 20,
                    medianCognitive: 4,
                    maxCognitive: 18,
                    functionsAboveThreshold: 1,
                    dominantBigO: "O(1)",
                    patternCounts: ["containsInFilter": 2]
                )
            ],
            summary: ComplexitySummary(
                totalFunctions: 20,
                medianCognitive: 4,
                p90Cognitive: 12,
                maxCognitive: 18,
                complexityDistribution: ["O(1)": 12, "O(n)": 6, "O(n²)": 2],
                totalPatterns: 2,
                patternBreakdown: ["containsInFilter": 2]
            )
        )
        #expect(report.projectID == "quality-gate-swift")
        #expect(report.modules.count == 1)
        #expect(report.summary.totalFunctions == 20)
        #expect(report.summary.medianCognitive == 4)
        #expect(report.summary.complexityDistribution["O(n²)"] == 2)
    }

    @Test("ComplexityReport round-trips through JSON")
    func reportCodable() throws {
        let report = ComplexityReport(
            projectID: "test",
            timestamp: Date(timeIntervalSince1970: 1747400000),
            modules: [
                ModuleComplexityReport(
                    moduleName: "Mod",
                    functionCount: 5,
                    medianCognitive: 3,
                    maxCognitive: 10,
                    functionsAboveThreshold: 0,
                    dominantBigO: "O(1)",
                    patternCounts: [:]
                )
            ],
            summary: ComplexitySummary(
                totalFunctions: 5,
                medianCognitive: 3,
                p90Cognitive: 8,
                maxCognitive: 10,
                complexityDistribution: ["O(1)": 5],
                totalPatterns: 0,
                patternBreakdown: [:]
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ComplexityReport.self, from: data)
        #expect(decoded == report)
    }

    // MARK: - ComplexityTrend

    @Test("ComplexityTrend wraps trend analysis with drift info")
    func trendProperties() {
        let trend = ComplexityTrend(
            metricName: "medianCognitive",
            trend: TrendAnalysis(
                metric: "medianCognitive",
                mean: 6.5,
                standardDeviation: 1.2,
                ci90Low: 4.5,
                ci90High: 8.5,
                ci95Low: 4.1,
                ci95High: 8.9,
                sampleSize: 14,
                validity: .valid,
                dailyValues: [5, 6, 7, 6, 7, 8, 6, 7, 6, 7, 6, 7, 6, 7]
            ),
            topDriftingModules: ["Parser", "StateMachine"],
            emergingPatterns: ["sortInLoop"],
            resolvedPatterns: []
        )
        #expect(trend.metricName == "medianCognitive")
        #expect(trend.topDriftingModules.count == 2)
        #expect(trend.emergingPatterns == ["sortInLoop"])
        #expect(trend.resolvedPatterns.isEmpty)
        #expect(abs(trend.trend.mean - 6.5) < 1e-6)
    }
}
