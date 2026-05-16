import Foundation
import Testing
@testable import ComplexityAnalyzer
@testable import QualityGateCore

@Suite("CallGraph Builder Tests")
struct CallGraphBuilderTests {

    // MARK: - Basic edge detection

    @Test("Detects simple function-to-function call")
    func simpleCall() {
        let code = """
        func helper() -> Int { return 42 }

        func caller() -> Int {
            return helper()
        }
        """
        let graph = buildGraph(code)
        #expect(graph.definedFunctions.contains("helper"))
        #expect(graph.definedFunctions.contains("caller"))
        let edges = graph.callees(of: "caller")
        #expect(edges.count == 1)
        #expect(edges[0].callee == "helper")
        #expect(edges[0].insideLoop == false)
    }

    @Test("Detects call inside a for loop")
    func callInsideLoop() throws {
        let code = """
        func process(_ item: Int) -> Int { return item * 2 }

        func batchProcess(items: [Int]) -> [Int] {
            var results: [Int] = []
            for item in items {
                results.append(process(item))
            }
            return results
        }
        """
        let graph = buildGraph(code)
        let edges = graph.callees(of: "batchProcess")
        let processEdge = try #require(edges.first { $0.callee == "process" })
        #expect(processEdge.insideLoop == true)
    }

    @Test("Detects call inside higher-order iteration (map/filter)")
    func callInsideHigherOrder() throws {
        let code = """
        func transform(_ x: Int) -> Int { return x + 1 }

        func applyAll(items: [Int]) -> [Int] {
            return items.map { transform($0) }
        }
        """
        let graph = buildGraph(code)
        let edges = graph.callees(of: "applyAll")
        let transformEdge = try #require(edges.first { $0.callee == "transform" })
        #expect(transformEdge.insideLoop == true)
    }

    @Test("Does not mark call outside loop as insideLoop")
    func callOutsideLoop() throws {
        let code = """
        func setup() -> Int { return 0 }

        func run(items: [Int]) -> Int {
            let base = setup()
            var sum = base
            for item in items {
                sum += item
            }
            return sum
        }
        """
        let graph = buildGraph(code)
        let edges = graph.callees(of: "run")
        let setupEdge = try #require(edges.first { $0.callee == "setup" })
        #expect(setupEdge.insideLoop == false)
    }

    // MARK: - Multiple calls and self-references

    @Test("Detects multiple callees from one function")
    func multipleCallees() {
        let code = """
        func a() -> Int { return 1 }
        func b() -> Int { return 2 }
        func c() -> Int { return 3 }

        func orchestrator() -> Int {
            return a() + b() + c()
        }
        """
        let graph = buildGraph(code)
        let edges = graph.callees(of: "orchestrator")
        let calleeNames = Set(edges.map(\.callee))
        #expect(calleeNames == ["a", "b", "c"])
    }

    @Test("Ignores calls to functions not defined in the module")
    func externalCallsIgnored() {
        let code = """
        func localWork() -> String {
            return String(42)
        }
        """
        let graph = buildGraph(code)
        #expect(graph.definedFunctions == ["localWork"])
        #expect(graph.edges.isEmpty)
    }

    @Test("Records self-recursive calls")
    func selfRecursion() {
        let code = """
        func factorial(n: Int) -> Int {
            guard n > 1 else { return 1 }
            return n * factorial(n: n - 1)
        }
        """
        let graph = buildGraph(code)
        let edges = graph.callees(of: "factorial")
        #expect(edges.count == 1)
        #expect(edges[0].callee == "factorial")
        #expect(edges[0].insideLoop == false)
    }

    // MARK: - Nested functions skipped

    @Test("Does not traverse into nested function declarations")
    func nestedFunctionIsolated() {
        let code = """
        func outer() -> Int {
            func inner() -> Int { return 1 }
            return inner()
        }

        func inner() -> Int { return 99 }
        """
        let graph = buildGraph(code)
        #expect(graph.definedFunctions.contains("outer"))
        #expect(graph.definedFunctions.contains("inner"))
        let outerEdges = graph.callees(of: "outer")
        #expect(outerEdges.first?.callee == "inner")
    }

    // MARK: - Helpers

    private func buildGraph(_ source: String) -> CallGraph {
        CallGraphBuilder.build(source: source, moduleName: "Test")
    }
}
