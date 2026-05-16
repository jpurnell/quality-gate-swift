import Foundation
import Testing
@testable import ComplexityAnalyzer
@testable import IJSSensor
@testable import QualityGateCore

@Suite("ComplexityTelemetryEmitter Tests")
struct ComplexityTelemetryEmitterTests {

    @Test("Emitter produces report with correct summary statistics")
    func emitterProducesSummary() {
        let records: [FunctionComplexityRecord] = [
            makeRecord(name: "a", module: "Core", cognitive: 2, bigO: "O(1)"),
            makeRecord(name: "b", module: "Core", cognitive: 8, bigO: "O(n)"),
            makeRecord(name: "c", module: "Core", cognitive: 15, bigO: "O(n²)"),
            makeRecord(name: "d", module: "Utils", cognitive: 3, bigO: "O(1)"),
            makeRecord(name: "e", module: "Utils", cognitive: 5, bigO: "O(n)"),
        ]

        let report = ComplexityTelemetryEmitter.buildReport(
            from: records,
            projectID: "test-project",
            timestamp: Date(timeIntervalSince1970: 1747400000),
            threshold: 10
        )

        #expect(report.projectID == "test-project")
        #expect(report.summary.totalFunctions == 5)
        #expect(report.summary.medianCognitive == 5)
        #expect(report.summary.maxCognitive == 15)
        #expect(report.summary.functionsAboveThreshold == 1)
        #expect(report.summary.complexityDistribution["O(1)"] == 2)
        #expect(report.summary.complexityDistribution["O(n)"] == 2)
        #expect(report.summary.complexityDistribution["O(n²)"] == 1)
    }

    @Test("Emitter groups records by module")
    func emitterGroupsByModule() {
        let records: [FunctionComplexityRecord] = [
            makeRecord(name: "a", module: "Alpha", cognitive: 4, bigO: "O(1)"),
            makeRecord(name: "b", module: "Alpha", cognitive: 6, bigO: "O(n)"),
            makeRecord(name: "c", module: "Beta", cognitive: 12, bigO: "O(n²)"),
        ]

        let report = ComplexityTelemetryEmitter.buildReport(
            from: records,
            projectID: "test",
            timestamp: Date(),
            threshold: 10
        )

        #expect(report.modules.count == 2)
        let alpha = report.modules.first { $0.moduleName == "Alpha" }
        let beta = report.modules.first { $0.moduleName == "Beta" }
        #expect(alpha?.functionCount == 2)
        #expect(alpha?.medianCognitive == 5)
        #expect(beta?.functionCount == 1)
        #expect(beta?.maxCognitive == 12)
        #expect(beta?.functionsAboveThreshold == 1)
    }

    @Test("Emitter counts patterns in breakdown")
    func emitterCountsPatterns() {
        let records: [FunctionComplexityRecord] = [
            makeRecord(name: "a", module: "M", cognitive: 5, bigO: "O(n²)",
                       patterns: [.containsInFilter(collection: "arr", line: 1)]),
            makeRecord(name: "b", module: "M", cognitive: 3, bigO: "O(n)",
                       patterns: [.containsInFilter(collection: "list", line: 2),
                                  .sortInLoop(line: 5)]),
        ]

        let report = ComplexityTelemetryEmitter.buildReport(
            from: records,
            projectID: "test",
            timestamp: Date(),
            threshold: 10
        )

        #expect(report.summary.totalPatterns == 3)
        #expect(report.summary.patternBreakdown["containsInFilter"] == 2)
        #expect(report.summary.patternBreakdown["sortInLoop"] == 1)
    }

    @Test("Emitter handles empty records")
    func emitterHandlesEmpty() {
        let report = ComplexityTelemetryEmitter.buildReport(
            from: [],
            projectID: "empty",
            timestamp: Date(),
            threshold: 10
        )

        #expect(report.summary.totalFunctions == 0)
        #expect(report.summary.medianCognitive == 0)
        #expect(report.modules.isEmpty)
    }

    // MARK: - Helpers

    private func makeRecord(
        name: String,
        module: String,
        cognitive: Int,
        bigO: String,
        patterns: [ComplexityPattern] = []
    ) -> FunctionComplexityRecord {
        FunctionComplexityRecord(
            functionName: name,
            moduleName: module,
            filePath: "<test>",
            startLine: 1,
            endLine: 10,
            cognitiveComplexity: cognitive,
            cognitiveBreakdown: [],
            estimatedTimeComplexity: bigO,
            complexityBasis: [],
            confidence: .high,
            detectedPatterns: patterns
        )
    }
}
