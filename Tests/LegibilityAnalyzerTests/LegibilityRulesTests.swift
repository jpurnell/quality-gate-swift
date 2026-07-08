import Foundation
import Testing
@testable import LegibilityAnalyzer
import QualityGateCore

@Suite("LegibilityRules")
struct LegibilityRulesTests {

    // MARK: - Rule 1: central-unoriented

    /// Core is depended on by A, B, C, D (fan-in 4); Util by A, B, C (fan-in 3).
    private func centralGraph() -> ModuleGraph {
        ModuleGraph(edges: [
            "A": ["Core", "Util"],
            "B": ["Core", "Util"],
            "C": ["Core", "Util"],
            "D": ["Core"],
        ])
    }

    @Test("central undocumented module is flagged as a note")
    func centralUndocumentedFlagged() {
        let diags = LegibilityRules.centralUnoriented(
            graph: centralGraph(),
            orientation: [
                ModuleOrientation(moduleName: "Core", hasOrientationDoc: false),
                ModuleOrientation(moduleName: "Util", hasOrientationDoc: false),
            ],
            config: .default
        )
        let flagged = diags.map(\.message)
        #expect(diags.allSatisfy { $0.severity == .note })
        #expect(diags.allSatisfy { $0.ruleId == "legibility.central-unoriented" })
        #expect(diags.allSatisfy { $0.suggestedFix?.contains("DocC catalog overview") == true })
        #expect(flagged.contains { $0.contains("Core") && $0.contains("4 modules") })
        #expect(flagged.contains { $0.contains("Util") })
    }

    @Test("a documented central module is not flagged")
    func documentedNotFlagged() {
        let diags = LegibilityRules.centralUnoriented(
            graph: centralGraph(),
            orientation: [
                ModuleOrientation(moduleName: "Core", hasOrientationDoc: true),
                ModuleOrientation(moduleName: "Util", hasOrientationDoc: true),
            ],
            config: .default
        )
        #expect(diags.isEmpty)
    }

    @Test("a module below the fan-in threshold is not flagged")
    func belowThresholdNotFlagged() {
        // Leaf depended on only once → fan-in 1, below default minFanInForCentral 3.
        let graph = ModuleGraph(edges: ["A": ["Small"]])
        let diags = LegibilityRules.centralUnoriented(
            graph: graph,
            orientation: [ModuleOrientation(moduleName: "Small", hasOrientationDoc: false)],
            config: .default
        )
        #expect(diags.isEmpty)
    }

    @Test("exempt modules are never flagged")
    func exemptNotFlagged() {
        let config = LegibilityAnalyzerConfig(exemptModules: ["Core"])
        let diags = LegibilityRules.centralUnoriented(
            graph: centralGraph(),
            orientation: [ModuleOrientation(moduleName: "Core", hasOrientationDoc: false)],
            config: config
        )
        #expect(diags.isEmpty)
    }

    @Test("topN caps the number of findings, keeping the highest fan-in")
    func topNRanking() {
        let config = LegibilityAnalyzerConfig(centralUnorientedTopN: 1)
        let diags = LegibilityRules.centralUnoriented(
            graph: centralGraph(),
            orientation: [
                ModuleOrientation(moduleName: "Core", hasOrientationDoc: false),
                ModuleOrientation(moduleName: "Util", hasOrientationDoc: false),
            ],
            config: config
        )
        #expect(diags.count == 1)
        #expect(diags[0].message.contains("Core"))   // fan-in 4 outranks Util's 3
    }

    // MARK: - Rule 2: module-cycle

    @Test("a dependency cycle is flagged as a note")
    func cycleFlagged() {
        let graph = ModuleGraph(edges: ["A": ["B"], "B": ["C"], "C": ["A"]])
        let diags = LegibilityRules.moduleCycles(graph: graph, config: .default)
        #expect(diags.count == 1)
        #expect(diags[0].severity == .note)
        #expect(diags[0].ruleId == "legibility.module-cycle")
        #expect(diags[0].message.contains("A"))
        #expect(diags[0].message.contains("B"))
        #expect(diags[0].message.contains("C"))
    }

    @Test("an acyclic graph produces no cycle notes")
    func acyclicNoCycle() {
        let graph = ModuleGraph(edges: ["A": ["B"], "B": ["C"]])
        #expect(LegibilityRules.moduleCycles(graph: graph, config: .default).isEmpty)
    }

    @Test("cycles are suppressed when flagCycles is off")
    func cyclesDisabled() {
        let graph = ModuleGraph(edges: ["A": ["B"], "B": ["A"]])
        let config = LegibilityAnalyzerConfig(flagCycles: false)
        #expect(LegibilityRules.moduleCycles(graph: graph, config: config).isEmpty)
    }

    // MARK: - Rule 3: over-public-symbol

    @Test("an unacknowledged over-public symbol becomes a note with a fix")
    func overPublicUnacknowledged() {
        let occ = OverPublicOccurrence(
            symbolName: "recalibrate",
            moduleName: "Sensor",
            filePath: "/Sources/Sensor/Sensor.swift",
            line: 42,
            acknowledged: false
        )
        let findings = LegibilityRules.overPublicSymbols([occ], config: .default)
        #expect(findings.diagnostics.count == 1)
        #expect(findings.compliance.isEmpty)
        #expect(findings.diagnostics[0].severity == .note)
        #expect(findings.diagnostics[0].ruleId == "legibility.over-public-symbol")
        #expect(findings.diagnostics[0].lineNumber == 42)
        #expect(findings.diagnostics[0].suggestedFix?.contains("internal") == true)
    }

    @Test("an acknowledged over-public symbol becomes a compliance record, not a note")
    func overPublicAcknowledged() {
        let occ = OverPublicOccurrence(
            symbolName: "reservedAPI",
            moduleName: "Sensor",
            filePath: "/Sources/Sensor/Sensor.swift",
            line: 10,
            acknowledged: true,
            acknowledgment: "legibility:reserved downstream"
        )
        let findings = LegibilityRules.overPublicSymbols([occ], config: .default)
        #expect(findings.diagnostics.isEmpty)
        #expect(findings.compliance.count == 1)
        #expect(findings.compliance[0].ruleId == "legibility.over-public-symbol")
        #expect(findings.compliance[0].annotation.contains("downstream"))
    }

    @Test("over-public rule is suppressed when disabled")
    func overPublicDisabled() {
        let occ = OverPublicOccurrence(
            symbolName: "x", moduleName: "M", filePath: "/f.swift", line: 1, acknowledged: false
        )
        let config = LegibilityAnalyzerConfig(flagOverPublicSymbols: false)
        let findings = LegibilityRules.overPublicSymbols([occ], config: config)
        #expect(findings.diagnostics.isEmpty)
        #expect(findings.compliance.isEmpty)
    }

    @Test("findings are ordered deterministically by file, line, name")
    func deterministicOrdering() {
        let occurrences = [
            OverPublicOccurrence(symbolName: "b", moduleName: "M", filePath: "/b.swift", line: 5, acknowledged: false),
            OverPublicOccurrence(symbolName: "a", moduleName: "M", filePath: "/a.swift", line: 9, acknowledged: false),
            OverPublicOccurrence(symbolName: "a", moduleName: "M", filePath: "/a.swift", line: 2, acknowledged: false),
        ]
        let findings = LegibilityRules.overPublicSymbols(occurrences, config: .default)
        let lines = findings.diagnostics.map { "\($0.filePath ?? ""):\($0.lineNumber ?? 0)" }
        #expect(lines == ["/a.swift:2", "/a.swift:9", "/b.swift:5"])
    }
}
