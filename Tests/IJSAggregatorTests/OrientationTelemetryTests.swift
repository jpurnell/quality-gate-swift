import Foundation
import Testing
@testable import IJSAggregator
@testable import IJSSensor

@Suite("Orientation Telemetry")
struct OrientationTelemetryTests {

    @Test("CorpusPath computes the orientation artifact path")
    func orientationPath() {
        let corpus = CorpusPath(basePath: "/tmp/corpus", projectID: "my-project")
        let date = Date(timeIntervalSince1970: 1_747_400_000)
        let path = corpus.orientationPath(for: date)
        #expect(path.contains("telemetry/my-project/"))
        #expect(path.hasSuffix("_orientation.json"))
    }

    @Test("writer writes an orientation report the reader can decode")
    func writeAndReadBack() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orientation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let corpus = CorpusPath(basePath: tempDir.path, projectID: "test-project")
        let timestamp = Date(timeIntervalSince1970: 1_747_400_000)
        let report = OrientationReport(
            projectID: "test-project",
            timestamp: timestamp,
            cards: [
                ModuleOrientationCard(
                    moduleID: "Core",
                    whatItDoes: nil,
                    why: "A foundational module — 2 other modules build on it.",
                    dependsOn: ["QualityGateCore"],
                    reliedOnBy: ["App", "Feature"],
                    role: "foundation",
                    source: .template,
                    generatedAt: timestamp
                )
            ],
            packageDependsOn: ["IconquerCore", "IconquerGameKit"],
            packageSummary: "The Iconquer product package."
        )

        let writer = TelemetryWriter()
        try await writer.writeOrientationReport(report, to: corpus)

        let data = try Data(contentsOf: URL(fileURLWithPath: corpus.orientationPath(for: timestamp)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OrientationReport.self, from: data)

        #expect(decoded == report)
        #expect(decoded.card(for: "Core")?.reliedOnBy == ["App", "Feature"])
        #expect(decoded.packageDependsOn == ["IconquerCore", "IconquerGameKit"])
        #expect(decoded.packageSummary == "The Iconquer product package.")
    }
}
