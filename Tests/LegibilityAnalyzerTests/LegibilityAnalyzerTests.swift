import Foundation
import Testing
@testable import LegibilityAnalyzer
import QualityGateCore

@Suite("LegibilityAnalyzer.analyze")
struct LegibilityAnalyzerAnalyzeTests {

    @Test("analyze combines all three rules and builds the reading-order map")
    func combinesRulesAndMap() {
        // Core is central (fan-in 3) and undocumented; X↔Y form a cycle.
        let graph = ModuleGraph(edges: [
            "A": ["Core"], "B": ["Core"], "C": ["Core"],
            "X": ["Y"], "Y": ["X"],
        ])
        let orientation = [ModuleOrientation(moduleName: "Core", hasOrientationDoc: false)]
        let over = [
            OverPublicOccurrence(
                symbolName: "hidden", moduleName: "Core",
                filePath: "/f.swift", line: 3, acknowledged: false
            )
        ]
        let result = LegibilityAnalyzer.analyze(
            graph: graph,
            orientation: orientation,
            overPublic: over,
            overPublicByModule: ["Core": 1],
            config: .default
        )
        let ruleIDs = Set(result.diagnostics.compactMap(\.ruleId))
        #expect(ruleIDs.contains("legibility.central-unoriented"))
        #expect(ruleIDs.contains("legibility.module-cycle"))
        #expect(ruleIDs.contains("legibility.over-public-symbol"))
        #expect(result.diagnostics.allSatisfy { $0.severity == .note })
        #expect(result.map.readingOrder.first == "Core")
    }

    @Test("acknowledged over-public becomes a compliance record, not a note")
    func acknowledgedCompliance() {
        let graph = ModuleGraph(edges: ["A": ["Core"]])
        let over = [
            OverPublicOccurrence(
                symbolName: "r", moduleName: "Core",
                filePath: "/f.swift", line: 1,
                acknowledged: true, acknowledgment: "reserved"
            )
        ]
        let result = LegibilityAnalyzer.analyze(
            graph: graph, orientation: [], overPublic: over,
            overPublicByModule: [:], config: .default
        )
        #expect(result.compliance.count == 1)
        #expect(!result.diagnostics.contains { $0.ruleId == "legibility.over-public-symbol" })
    }

    @Test("a clean graph produces no diagnostics")
    func cleanGraph() {
        let graph = ModuleGraph(edges: ["A": ["Core"]])
        let orientation = [ModuleOrientation(moduleName: "Core", hasOrientationDoc: true)]
        let result = LegibilityAnalyzer.analyze(
            graph: graph, orientation: orientation, overPublic: [],
            overPublicByModule: [:], config: .default
        )
        #expect(result.diagnostics.isEmpty)
    }
}
