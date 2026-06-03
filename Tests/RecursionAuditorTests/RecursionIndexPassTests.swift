import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

@Suite("RecursionIndexPass Tests")
struct RecursionIndexPassTests {

    // MARK: - Tarjan SCC Algorithm

    @Test("Tarjan SCC finds a simple 2-node cycle")
    func tarjanFindsSimpleCycle() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:4test1ayyF", to: "s:4test1byyF")
        graph.addEdge(from: "s:4test1byyF", to: "s:4test1ayyF")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.count == 1)
        #expect(cyclicSCCs[0].count == 2)
    }

    @Test("Tarjan SCC finds a 3-node cycle")
    func tarjanFindsThreeNodeCycle() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:4test1ayyF", to: "s:4test1byyF")
        graph.addEdge(from: "s:4test1byyF", to: "s:4test1cyyF")
        graph.addEdge(from: "s:4test1cyyF", to: "s:4test1ayyF")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.count == 1)
        #expect(cyclicSCCs[0].count == 3)
    }

    @Test("Tarjan SCC returns singleton for non-cyclic node")
    func tarjanNoCycle() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:4test1ayyF", to: "s:4test1byyF")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.isEmpty)
    }

    @Test("Tarjan SCC handles multiple independent cycles")
    func tarjanMultipleCycles() {
        let graph = USRCallGraph()
        graph.addEdge(from: "usr:a", to: "usr:b")
        graph.addEdge(from: "usr:b", to: "usr:a")
        graph.addEdge(from: "usr:c", to: "usr:d")
        graph.addEdge(from: "usr:d", to: "usr:c")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.count == 2)
    }

    @Test("Tarjan SCC handles self-loop")
    func tarjanSelfLoop() {
        let graph = USRCallGraph()
        graph.addEdge(from: "usr:a", to: "usr:a")

        let sccs = graph.findStronglyConnectedComponents()
        let selfLoops = sccs.filter { component in
            component.count == 1 && graph.hasSelfEdge(component.first ?? "")
        }
        #expect(selfLoops.count == 1)
    }

    @Test("Tarjan SCC handles empty graph")
    func tarjanEmptyGraph() {
        let graph = USRCallGraph()
        let sccs = graph.findStronglyConnectedComponents()
        #expect(sccs.isEmpty)
    }

    @Test("Tarjan SCC handles isolated nodes with no edges")
    func tarjanIsolatedNodes() {
        let graph = USRCallGraph()
        graph.addNode("usr:a")
        graph.addNode("usr:b")
        graph.addNode("usr:c")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.isEmpty)
    }

    // MARK: - Scale

    @Test("Tarjan SCC handles 1000-node linear chain without cycles")
    func tarjanScaleLinearChain() {
        let graph = USRCallGraph()
        for i in 0..<1000 {
            graph.addEdge(from: "usr:node\(i)", to: "usr:node\(i + 1)")
        }

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.isEmpty)
    }

    @Test("Tarjan SCC handles 1000-node ring cycle")
    func tarjanScaleRingCycle() {
        let graph = USRCallGraph()
        let nodeCount = 1000
        for i in 0..<nodeCount {
            graph.addEdge(from: "usr:node\(i)", to: "usr:node\((i + 1) % nodeCount)")
        }

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.count == 1)
        #expect(cyclicSCCs[0].count == nodeCount)
    }

    // MARK: - USR-based name collision elimination

    @Test("USR-based graph distinguishes overloaded methods with same display name")
    func usrDistinguishesOverloads() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:6ModuleA1AV7processyyF", to: "s:6ModuleB1BV7processyyF")

        let sccs = graph.findStronglyConnectedComponents()
        let cyclicSCCs = sccs.filter { $0.count >= 2 }
        #expect(cyclicSCCs.isEmpty)
    }

    // MARK: - Cross-module cycle detection

    @Test("Detects cross-module mutual recursion cycle")
    func crossModuleCycleDetection() {
        let graph = USRCallGraph()
        let usrA = "s:7ModuleA4funcyyF"
        let usrB = "s:7ModuleB4funcyyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrA)
        graph.setModuleName(usrA, module: "ModuleA")
        graph.setModuleName(usrB, module: "ModuleB")

        let sccs = graph.findStronglyConnectedComponents()
        let crossModuleCycles = sccs.filter { $0.count >= 2 && graph.isCrossModule($0) }
        #expect(crossModuleCycles.count == 1)
    }

    @Test("Same-module cycle is not flagged as cross-module")
    func sameModuleCycleNotCrossModule() {
        let graph = USRCallGraph()
        let usrA = "s:7ModuleA1ayyF"
        let usrB = "s:7ModuleA1byyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrA)
        graph.setModuleName(usrA, module: "ModuleA")
        graph.setModuleName(usrB, module: "ModuleA")

        let sccs = graph.findStronglyConnectedComponents()
        let crossModuleCycles = sccs.filter { $0.count >= 2 && graph.isCrossModule($0) }
        #expect(crossModuleCycles.isEmpty)
    }

    // MARK: - Protocol witness cycle detection

    @Test("Detects protocol witness cycle pattern")
    func protocolWitnessCycle() {
        let graph = USRCallGraph()
        let usrDefaultFoo = "s:7ModuleP1PE3fooyyF"
        let usrBar = "s:7ModuleP12ConcreteTypeV3baryyF"
        let usrWitnessFoo = "s:7ModuleP12ConcreteTypeV3fooyyF"
        graph.addEdge(from: usrDefaultFoo, to: usrBar)
        graph.addEdge(from: usrBar, to: usrWitnessFoo)
        graph.addEdge(from: usrWitnessFoo, to: usrDefaultFoo)
        graph.markAsProtocolWitness(usrWitnessFoo)
        graph.markAsDefaultImplementation(usrDefaultFoo)

        let sccs = graph.findStronglyConnectedComponents()
        let witnessCycles = sccs.filter { $0.count >= 2 && graph.isProtocolWitnessCycle($0) }
        #expect(witnessCycles.count == 1)
    }

    @Test("Normal protocol conformance without cycle is not flagged")
    func normalProtocolConformanceNoCycle() {
        let graph = USRCallGraph()
        graph.addEdge(from: "s:Concrete3fooyyF", to: "s:P3fooyyF")
        graph.markAsProtocolWitness("s:Concrete3fooyyF")
        graph.markAsDefaultImplementation("s:P3fooyyF")

        let sccs = graph.findStronglyConnectedComponents()
        let witnessCycles = sccs.filter { $0.count >= 2 && graph.isProtocolWitnessCycle($0) }
        #expect(witnessCycles.isEmpty)
    }

    // MARK: - Diagnostic generation

    @Test("Cross-module cycle diagnostic uses correct rule ID")
    func crossModuleCycleDiagnosticRuleId() {
        let graph = USRCallGraph()
        let usrA = "s:7ModuleA4funcyyF"
        let usrB = "s:7ModuleB4funcyyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrA)
        graph.setModuleName(usrA, module: "ModuleA")
        graph.setModuleName(usrB, module: "ModuleB")
        graph.setSymbolInfo(usrA, info: SymbolInfo(displayName: "func()", filePath: "A.swift", line: 1, column: 1, moduleName: "ModuleA"))
        graph.setSymbolInfo(usrB, info: SymbolInfo(displayName: "func()", filePath: "B.swift", line: 1, column: 1, moduleName: "ModuleB"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        let crossModuleDiags = diagnostics.filter { $0.ruleId == "recursion.cross-module-cycle" }
        #expect(crossModuleDiags.count >= 2)
        #expect(crossModuleDiags.allSatisfy { $0.severity == .warning })
    }

    @Test("Protocol witness cycle diagnostic uses correct rule ID")
    func protocolWitnessCycleDiagnosticRuleId() {
        let graph = USRCallGraph()
        let usrA = "s:P3defaultFooyyF"
        let usrB = "s:Concrete3baryyF"
        let usrC = "s:Concrete3fooyyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrC)
        graph.addEdge(from: usrC, to: usrA)
        graph.markAsDefaultImplementation(usrA)
        graph.markAsProtocolWitness(usrC)
        graph.setModuleName(usrA, module: "M")
        graph.setModuleName(usrB, module: "M")
        graph.setModuleName(usrC, module: "M")
        graph.setSymbolInfo(usrA, info: SymbolInfo(displayName: "foo()", filePath: "P.swift", line: 1, column: 1, moduleName: "M"))
        graph.setSymbolInfo(usrB, info: SymbolInfo(displayName: "bar()", filePath: "C.swift", line: 1, column: 1, moduleName: "M"))
        graph.setSymbolInfo(usrC, info: SymbolInfo(displayName: "foo()", filePath: "C.swift", line: 5, column: 1, moduleName: "M"))

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        let witnessDiags = diagnostics.filter { $0.ruleId == "recursion.protocol-witness-cycle" }
        #expect(!witnessDiags.isEmpty)
        #expect(witnessDiags.allSatisfy { $0.severity == .warning })
    }

    // MARK: - Graceful degradation

    @Test("Pass 2 gracefully skips when index is unavailable")
    func gracefulDegradationNoIndex() {
        let result = RecursionIndexPass.runWithoutIndex()
        #expect(result.count == 1)
        #expect(result[0].severity == .note)
        #expect(result[0].ruleId == "recursion.index_pass.skipped")
    }

    // MARK: - Configuration

    @Test("RecursionAuditorConfig defaults to useIndexStore true")
    func configDefaultsToTrue() {
        let config = RecursionAuditorConfig()
        #expect(config.useIndexStore == true)
    }

    @Test("Configuration includes recursion config")
    func configurationIncludesRecursion() {
        let config = Configuration()
        #expect(config.recursion.useIndexStore == true)
    }

    // MARK: - Severity demotion

    @Test("Name-based mutual cycle is demoted to note when Pass 2 runs")
    func nameBasedFallbackDemotedToNote() {
        let nameBasedDiag = Diagnostic(
            severity: .warning,
            message: "function 'a()' participates in a mutual recursion cycle with no base case",
            filePath: "A.swift",
            lineNumber: 1,
            columnNumber: 1,
            ruleId: "recursion.mutual-cycle",
            suggestedFix: "Add a guard-driven base case."
        )

        let demoted = RecursionIndexPass.demoteToNote(nameBasedDiag)
        #expect(demoted.severity == .note)
        #expect(demoted.ruleId == "recursion.mutual-cycle")
        #expect(demoted.message.contains("name-based"))
    }

    // MARK: - Base case filtering

    @Test("Cycle with base case is not flagged")
    func cycleWithBaseCaseNotFlagged() {
        let graph = USRCallGraph()
        let usrA = "s:M1ayyF"
        let usrB = "s:M1byyF"
        graph.addEdge(from: usrA, to: usrB)
        graph.addEdge(from: usrB, to: usrA)
        graph.setModuleName(usrA, module: "M")
        graph.setModuleName(usrB, module: "M")
        graph.setSymbolInfo(usrA, info: SymbolInfo(displayName: "a()", filePath: "A.swift", line: 1, column: 1, moduleName: "M"))
        graph.setSymbolInfo(usrB, info: SymbolInfo(displayName: "b()", filePath: "B.swift", line: 1, column: 1, moduleName: "M"))
        graph.markHasBaseCase(usrA)

        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph)
        let cycleDiags = diagnostics.filter { $0.ruleId == "recursion.mutual-cycle" }
        #expect(cycleDiags.isEmpty)
    }
}
