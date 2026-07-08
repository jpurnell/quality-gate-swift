import Foundation
import Testing
@testable import LegibilityAnalyzer
import IJSSensor

@Suite("LegibilityAnalyzer.orientationCards")
struct OrientationCardsTests {

    private let ts = Date(timeIntervalSince1970: 1_777_536_311)

    // A → Core, B → Core, Core → Util.
    private func graph() -> ModuleGraph {
        ModuleGraph(edges: ["A": ["Core"], "B": ["Core"], "Core": ["Util"]])
    }

    @Test("reliedOnBy is the sorted set of dependents (the factual anchor)")
    func reliedOnBy() {
        let cards = LegibilityAnalyzer.orientationCards(graph: graph(), orientation: [], timestamp: ts)
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.moduleID, $0) })
        #expect(byID["Core"]?.reliedOnBy == ["A", "B"])
        #expect(byID["Util"]?.reliedOnBy == ["Core"])
        #expect(byID["A"]?.reliedOnBy == [])
    }

    @Test("role is inferred from graph position")
    func role() {
        let cards = LegibilityAnalyzer.orientationCards(graph: graph(), orientation: [], timestamp: ts)
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.moduleID, $0) })
        #expect(byID["A"]?.role == "entry-point")   // fan-in 0
        #expect(byID["Util"]?.role == "foundation") // fan-out 0
    }

    @Test("whatItDoes points at the DocC overview only when one exists")
    func whatItDoes() {
        let orientation = [
            ModuleOrientation(moduleName: "Core", hasOrientationDoc: true),
            ModuleOrientation(moduleName: "A", hasOrientationDoc: false),
        ]
        let cards = LegibilityAnalyzer.orientationCards(graph: graph(), orientation: orientation, timestamp: ts)
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.moduleID, $0) })
        #expect(byID["Core"]?.whatItDoes == "See the module's DocC overview.")
        #expect(byID["A"]?.whatItDoes == nil)
    }

    @Test("why explains the structural role; source is template")
    func whyAndSource() {
        let cards = LegibilityAnalyzer.orientationCards(graph: graph(), orientation: [], timestamp: ts)
        let core = cards.first { $0.moduleID == "Core" }
        #expect(core?.why?.contains("foundational") == true)
        #expect(cards.allSatisfy { $0.source == .template })
        #expect(cards.allSatisfy { $0.generatedAt == ts })
    }

    @Test("templateWhy covers every role")
    func templateWhyRoles() {
        #expect(LegibilityAnalyzer.templateWhy(role: "foundation", fanIn: 3)?.contains("foundational") == true)
        #expect(LegibilityAnalyzer.templateWhy(role: "entry-point", fanIn: 0)?.contains("entry point") == true)
        #expect(LegibilityAnalyzer.templateWhy(role: "orchestrator", fanIn: 1)?.contains("Coordinates") == true)
        #expect(LegibilityAnalyzer.templateWhy(role: "intermediate", fanIn: 2)?.contains("mid-layer") == true)
        #expect(LegibilityAnalyzer.templateWhy(role: "isolated", fanIn: 0)?.contains("Standalone") == true)
    }
}
