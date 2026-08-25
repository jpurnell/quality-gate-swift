import Foundation
import Testing
import SwiftSyntax
import SwiftParser
@testable import RecursionAuditor

/// `TheIndexKnowsWhichBranchReturns.md`: Pass 1 records the callee positions of every
/// `return <call>` it cannot judge, and Pass 2 resolves each name against the index.
/// A cycle is bounded when some participant has a return whose every name resolves
/// outside the cycle.
@Suite("Candidate base cases — Pass 1 collection")
struct CandidateBaseCaseCollectionTests {

    private func collect(_ source: String) -> [CandidateBaseCase] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "test.swift", tree: tree)
        return candidateBaseCases(in: Syntax(tree), converter: converter)
    }

    @Test("records a `return f(x)` with the callee's position")
    func recordsReturnOfCall() {
        let candidates = collect("""
        func a() -> Int {
            return b(1)
        }
        """)
        #expect(candidates.count == 1)
        #expect(candidates.first?.calleePositions.count == 1)
        #expect(candidates.first?.calleePositions.first?.line == 2)
    }

    @Test("does not record `return 0` — syntax already judged it")
    func skipsNonCallReturn() {
        let candidates = collect("""
        func a() -> Int {
            return 0
        }
        """)
        #expect(candidates.isEmpty)
    }

    @Test("does not record a call that is not a return's value")
    func skipsNonReturnCall() {
        // Two statements, so the block is not a single-expression value — a lone-call
        // body would be an implicit return (SE-0255) and correctly recorded.
        let candidates = collect("""
        func a() {
            b(1)
            x += 1
        }
        """)
        #expect(candidates.isEmpty)
    }

    @Test("records every callee name in a nested return expression, at any depth")
    func recordsNestedCallees() {
        // `return self.init(impl: .collated(expression, name))` — the GRDB shape.
        // Two callee names: `init` and `collated`.
        let candidates = collect("""
        func a() -> Self {
            return self.init(impl: .collated(expression, name))
        }
        """)
        #expect(candidates.count == 1)
        #expect(candidates.first?.calleePositions.count == 2)
    }

    @Test("records a single-expression branch value that is a call — the implicit return")
    func recordsImplicitReturnCall() {
        let candidates = collect("""
        func a() -> Int {
            if x { b(1) } else { c(2) }
        }
        """)
        #expect(candidates.count == 2)
    }
}

@Suite("Candidate base cases — Pass 2 adjudication")
struct CandidateBaseCaseAdjudicationTests {

    /// A two-node mutual cycle `a → b → a` with symbol info, no syntactic base case.
    private func makeCycle() -> USRCallGraph {
        let graph = USRCallGraph()
        graph.addEdge(from: "usr:a", to: "usr:b")
        graph.addEdge(from: "usr:b", to: "usr:a")
        graph.setSymbolInfo("usr:a", info: SymbolInfo(
            displayName: "a()", filePath: "/p/A.swift", line: 1, column: 6, moduleName: "M"))
        graph.setSymbolInfo("usr:b", info: SymbolInfo(
            displayName: "b()", filePath: "/p/A.swift", line: 10, column: 6, moduleName: "M"))
        graph.setModuleName("usr:a", module: "M")
        graph.setModuleName("usr:b", module: "M")
        return graph
    }

    @Test("a candidate whose every name resolves outside the cycle bounds it")
    func exitingCandidateBoundsTheCycle() {
        let graph = makeCycle()
        graph.setCandidateBaseCases("usr:a", [
            CandidateBaseCase(calleePositions: [CalleePosition(line: 3, column: 16)])
        ])
        // The name at 3:16 resolves to an enum case outside the component.
        let resolution = SymbolResolution(positions: [
            FilePosition(path: "/p/A.swift", line: 3, column: 16): "usr:enum-case"
        ])
        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph, resolution: resolution)
        #expect(!diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    @Test("a candidate naming a component member does not bound the cycle")
    func inCycleCandidateDoesNotBound() {
        let graph = makeCycle()
        graph.setCandidateBaseCases("usr:a", [
            CandidateBaseCase(calleePositions: [CalleePosition(line: 3, column: 16)])
        ])
        // The name at 3:16 resolves back into the cycle — this branch re-enters it.
        let resolution = SymbolResolution(positions: [
            FilePosition(path: "/p/A.swift", line: 3, column: 16): "usr:b"
        ])
        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph, resolution: resolution)
        #expect(diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    @Test("an unresolvable position counts as staying in the cycle — the safe direction")
    func unresolvablePositionFailsTowardReporting() {
        let graph = makeCycle()
        graph.setCandidateBaseCases("usr:a", [
            CandidateBaseCase(calleePositions: [CalleePosition(line: 3, column: 16)])
        ])
        let diagnostics = RecursionIndexPass.generateDiagnostics(
            from: graph, resolution: SymbolResolution(positions: [:]))
        #expect(diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    @Test("one name outside and one inside does not bound — every name must exit")
    func mixedResolutionDoesNotBound() {
        let graph = makeCycle()
        graph.setCandidateBaseCases("usr:a", [
            CandidateBaseCase(calleePositions: [
                CalleePosition(line: 3, column: 16),
                CalleePosition(line: 3, column: 30),
            ])
        ])
        let resolution = SymbolResolution(positions: [
            FilePosition(path: "/p/A.swift", line: 3, column: 16): "usr:outside",
            FilePosition(path: "/p/A.swift", line: 3, column: 30): "usr:b",
        ])
        let diagnostics = RecursionIndexPass.generateDiagnostics(from: graph, resolution: resolution)
        #expect(diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    @Test("a syntactic base case still short-circuits without consulting resolution")
    func syntacticBaseCaseShortCircuits() {
        let graph = makeCycle()
        graph.markHasBaseCase("usr:b")
        let diagnostics = RecursionIndexPass.generateDiagnostics(
            from: graph, resolution: SymbolResolution(positions: [:]))
        #expect(!diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }
}
