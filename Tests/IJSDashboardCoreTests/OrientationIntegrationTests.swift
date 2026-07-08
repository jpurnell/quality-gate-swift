import Foundation
import Testing
@testable import IJSDashboardCore
import IJSAggregator
import IJSSensor

/// End-to-end over the real data path: emit orientation reports with the actual
/// TelemetryWriter, read them back with CorpusReader, and invert them with
/// PortfolioOrientation — the same code the dashboard runs, minus the TUI.
@Suite("Orientation corpus integration")
struct OrientationIntegrationTests {

    @Test("emit → CorpusReader → inversion yields cross-package relied-on-by")
    func endToEnd() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orient-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let ts = Date(timeIntervalSince1970: 1_777_536_311)
        let writer = TelemetryWriter()

        func emit(_ id: String, builtFrom: [String], summary: String?) async throws {
            let report = OrientationReport(
                projectID: id, timestamp: ts, cards: [],
                packageDependsOn: builtFrom, packageSummary: summary
            )
            try await writer.writeOrientationReport(report, to: CorpusPath(basePath: tempDir.path, projectID: id))
        }

        // An Iconquer-shaped cluster: a core library, an app and a CLI built on it.
        try await emit("IconquerCore", builtFrom: [], summary: "Core game logic and models.")
        try await emit("IconquerApp", builtFrom: ["IconquerCore"], summary: "The game app.")
        try await emit("IconquerCLI", builtFrom: ["IconquerCore"], summary: nil)

        let reader = CorpusReader(corpusPath: tempDir.path)
        let reports = try reader.loadAllOrientationReports()
        #expect(reports.count == 3)

        let cards = PortfolioOrientation.cards(from: reports, knownProjects: Set(reports.keys))

        // Core is the foundation library everything builds on.
        #expect(cards["IconquerCore"]?.reliedOnBy == ["IconquerApp", "IconquerCLI"])
        #expect(cards["IconquerCore"]?.role == "foundation library")
        #expect(cards["IconquerCore"]?.whatItDoes == "Core game logic and models.")
        // App is a top-level product built from Core.
        #expect(cards["IconquerApp"]?.dependsOn == ["IconquerCore"])
        #expect(cards["IconquerApp"]?.reliedOnBy == [])
        #expect(cards["IconquerApp"]?.role == "product")
    }
}
