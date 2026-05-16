import Foundation
import Testing
@testable import IJSAggregator
@testable import IJSSensor

@Suite("Complexity Telemetry Tests")
struct ComplexityTelemetryTests {

    // MARK: - CorpusPath

    @Test("CorpusPath computes complexity artifact path")
    func complexityPath() {
        let corpus = CorpusPath(basePath: "/tmp/corpus", projectID: "my-project")
        let date = Date(timeIntervalSince1970: 1747400000) // 2025-05-16 approx
        let path = corpus.complexityPath(for: date)
        #expect(path.contains("telemetry/my-project/"))
        #expect(path.hasSuffix("_complexity.json"))
    }

    // MARK: - TelemetryWriter round-trip

    @Test("TelemetryWriter writes and reads complexity report")
    func writeAndReadComplexity() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("complexity-test-\(UUID().uuidString)")
        // SAFETY: temporary test directory, cleaned up after test
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) } // silent: best-effort cleanup

        let corpus = CorpusPath(basePath: tempDir.path, projectID: "test-project")
        let timestamp = Date(timeIntervalSince1970: 1747400000)

        let report = ComplexityReport(
            projectID: "test-project",
            timestamp: timestamp,
            modules: [
                ModuleComplexityReport(
                    moduleName: "Core",
                    functionCount: 10,
                    medianCognitive: 3,
                    maxCognitive: 15,
                    functionsAboveThreshold: 1,
                    dominantBigO: "O(n)",
                    patternCounts: ["containsInFilter": 1]
                )
            ],
            summary: ComplexitySummary(
                totalFunctions: 10,
                medianCognitive: 3,
                p90Cognitive: 12,
                maxCognitive: 15,
                complexityDistribution: ["O(1)": 6, "O(n)": 3, "O(n²)": 1],
                totalPatterns: 1,
                patternBreakdown: ["containsInFilter": 1]
            )
        )

        let writer = TelemetryWriter()
        try await writer.writeComplexityReport(report, to: corpus)

        let reports = try await writer.readComplexityReports(
            from: corpus,
            startDate: timestamp.addingTimeInterval(-86400),
            endDate: timestamp.addingTimeInterval(86400)
        )
        #expect(reports.count == 1)
        #expect(reports[0].projectID == "test-project")
        #expect(reports[0].summary.totalFunctions == 10)
        #expect(reports[0].modules[0].moduleName == "Core")
    }

    @Test("Reading complexity reports from empty corpus returns empty array")
    func readEmptyCorpus() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("complexity-empty-\(UUID().uuidString)")
        // SAFETY: temporary test directory, cleaned up after test
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) } // silent: best-effort cleanup

        let corpus = CorpusPath(basePath: tempDir.path, projectID: "empty-project")
        let writer = TelemetryWriter()
        let reports = try await writer.readComplexityReports(
            from: corpus,
            startDate: Date().addingTimeInterval(-86400),
            endDate: Date()
        )
        #expect(reports.isEmpty)
    }
}
