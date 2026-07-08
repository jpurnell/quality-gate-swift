import Foundation
import Testing
@testable import LegibilityAnalyzer

@Suite("ModuleGraph")
struct ModuleGraphTests {

    // MARK: - Membership & adjacency

    @Test("modules includes both edge sources and edge targets")
    func modulesUnion() {
        // A → B, A → C.  C never appears as a key.
        let graph = ModuleGraph(edges: ["A": ["B", "C"]])
        #expect(graph.modules == ["A", "B", "C"])
    }

    @Test("dependencies are out-edges; dependents are in-edges")
    func dependenciesAndDependents() {
        let graph = ModuleGraph(edges: ["A": ["C"], "B": ["C"]])
        #expect(graph.dependencies(of: "A") == ["C"])
        #expect(graph.dependencies(of: "C") == [])
        // C is relied on by both A and B — "what relies on it".
        #expect(graph.dependents(of: "C") == ["A", "B"])
    }

    @Test("fanIn counts dependents; fanOut counts dependencies")
    func fanInFanOut() {
        let graph = ModuleGraph(edges: ["A": ["B", "C"], "B": ["C"]])
        #expect(graph.fanIn("C") == 2)   // relied on by A and B
        #expect(graph.fanIn("B") == 1)   // relied on by A
        #expect(graph.fanIn("A") == 0)   // relied on by no one
        #expect(graph.fanOut("A") == 2)
        #expect(graph.fanOut("C") == 0)
    }

    // MARK: - Weighted fan-in

    @Test("weightedFanIn falls back to 1 per edge with no weights")
    func weightedFanInUnweighted() {
        let graph = ModuleGraph(edges: ["A": ["C"], "B": ["C"]])
        #expect(graph.weightedFanIn("C") == 2)
    }

    @Test("weightedFanIn sums recorded reference counts")
    func weightedFanInWeighted() {
        let graph = ModuleGraph(
            edges: ["A": ["C"], "B": ["C"]],
            weights: ["A": ["C": 7], "B": ["C": 3]]
        )
        #expect(graph.weightedFanIn("C") == 10)
        // A missing weight for an existing edge falls back to 1.
        let mixed = ModuleGraph(
            edges: ["A": ["C"], "B": ["C"]],
            weights: ["A": ["C": 7]]
        )
        #expect(mixed.weightedFanIn("C") == 8)
    }

    // MARK: - Strongly-connected components

    @Test("an acyclic graph yields one component per module")
    func sccAcyclic() {
        let graph = ModuleGraph(edges: ["A": ["B", "C"], "B": ["C"]])
        let sccs = graph.stronglyConnectedComponents()
        #expect(sccs == [["C"], ["B"], ["A"]])
        #expect(graph.cycles().isEmpty)
    }

    @Test("a 3-cycle collapses to a single component")
    func sccCycle() {
        let graph = ModuleGraph(edges: ["A": ["B"], "B": ["C"], "C": ["A"]])
        let sccs = graph.stronglyConnectedComponents()
        #expect(sccs.count == 1)
        #expect(Set(sccs[0]) == ["A", "B", "C"])
        let cycles = graph.cycles()
        #expect(cycles.count == 1)
        #expect(Set(cycles[0]) == ["A", "B", "C"])
    }

    @Test("a self-referencing module is reported as a cycle")
    func selfLoopIsCycle() {
        let graph = ModuleGraph(edges: ["A": ["A"], "B": ["A"]])
        let cycles = graph.cycles()
        #expect(cycles == [["A"]])
    }

    // MARK: - Reading order

    @Test("reading order puts the most foundational module first")
    func readingOrderFoundationalFirst() {
        // C is depended on by A and B; B by A. Read C, then B, then A.
        let graph = ModuleGraph(edges: ["A": ["B", "C"], "B": ["C"]])
        #expect(graph.topologicalReadingOrder() == ["C", "B", "A"])
    }

    @Test("reading order breaks fan-in ties deterministically by name")
    func readingOrderDeterministicTies() {
        // B and C are both leaves relied on once each (by A) — tie on fan-in.
        let graph = ModuleGraph(edges: ["A": ["B", "C"]])
        let order = graph.topologicalReadingOrder()
        // Leaves emitted before A; tie broken by name → B before C.
        #expect(order == ["B", "C", "A"])
    }

    @Test("reading order is stable across repeated calls")
    func readingOrderStable() {
        let graph = ModuleGraph(edges: ["A": ["B", "C"], "B": ["C"], "D": ["A"]])
        #expect(graph.topologicalReadingOrder() == graph.topologicalReadingOrder())
    }
}
