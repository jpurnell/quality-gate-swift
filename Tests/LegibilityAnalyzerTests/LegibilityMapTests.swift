import Foundation
import Testing
@testable import LegibilityAnalyzer

@Suite("LegibilityMap")
struct LegibilityMapTests {

    // A → Core, B → Core, A → Util, Util → Core.
    private func graph() -> ModuleGraph {
        ModuleGraph(edges: [
            "A": ["Core", "Util"],
            "B": ["Core"],
            "Util": ["Core"],
        ])
    }

    @Test("reading order matches the graph and is foundation-first")
    func readingOrder() {
        let map = LegibilityMapBuilder.build(
            graph: graph(),
            orientation: [],
            overPublicByModule: [:]
        )
        #expect(map.readingOrder == graph().topologicalReadingOrder())
        #expect(map.readingOrder.first == "Core")   // fan-in 3, most foundational
    }

    @Test("cards carry accurate fan-in, fan-out, orientation, and over-public counts")
    func cardFacts() {
        let map = LegibilityMapBuilder.build(
            graph: graph(),
            orientation: [ModuleOrientation(moduleName: "Core", hasOrientationDoc: true)],
            overPublicByModule: ["Core": 2]
        )
        let core = map.cards.first { $0.moduleName == "Core" }
        #expect(core?.fanIn == 3)
        #expect(core?.fanOut == 0)
        #expect(core?.hasOrientationDoc == true)
        #expect(core?.overPublicCount == 2)
        #expect(core?.role == "foundation")
        // Cards are ordered to match the reading order.
        #expect(map.cards.map(\.moduleName) == map.readingOrder)
    }

    @Test("role inference covers foundation, entry-point, orchestrator, intermediate, isolated")
    func roleInference() {
        #expect(LegibilityMapBuilder.inferRole(fanIn: 3, fanOut: 0) == "foundation")
        #expect(LegibilityMapBuilder.inferRole(fanIn: 4, fanOut: 1) == "foundation")
        #expect(LegibilityMapBuilder.inferRole(fanIn: 0, fanOut: 2) == "entry-point")
        #expect(LegibilityMapBuilder.inferRole(fanIn: 1, fanOut: 4) == "orchestrator")
        #expect(LegibilityMapBuilder.inferRole(fanIn: 2, fanOut: 2) == "intermediate")
        #expect(LegibilityMapBuilder.inferRole(fanIn: 0, fanOut: 0) == "isolated")
    }

    @Test("markdown renders the reading order and a card table")
    func markdownRendering() {
        let map = LegibilityMapBuilder.build(
            graph: graph(),
            orientation: [ModuleOrientation(moduleName: "Core", hasOrientationDoc: true)],
            overPublicByModule: [:]
        )
        let md = LegibilityMapRenderer.markdown(map)
        #expect(md.contains("# Codebase Reading Order"))
        #expect(md.contains("1. Core"))
        #expect(md.contains("| Core | foundation |"))
        #expect(!md.contains("## Dependency Cycles"))   // acyclic
    }

    @Test("markdown includes a cycles section when cycles exist")
    func markdownCycles() {
        let cyclic = ModuleGraph(edges: ["A": ["B"], "B": ["A"]])
        let map = LegibilityMapBuilder.build(graph: cyclic, orientation: [], overPublicByModule: [:])
        let md = LegibilityMapRenderer.markdown(map)
        #expect(md.contains("## Dependency Cycles"))
        #expect(md.contains("A → B"))
    }

    @Test("JSON round-trips losslessly")
    func jsonRoundTrip() throws {
        let map = LegibilityMapBuilder.build(
            graph: graph(),
            orientation: [ModuleOrientation(moduleName: "Core", hasOrientationDoc: true)],
            overPublicByModule: ["Core": 2]
        )
        let json = try LegibilityMapRenderer.json(map)
        let decoded = try JSONDecoder().decode(LegibilityMap.self, from: Data(json.utf8))
        #expect(decoded == map)
    }
}
