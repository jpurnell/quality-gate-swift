import Foundation
import Testing
@testable import ComplexityAnalyzer
@testable import QualityGateCore

@Suite("BigO Estimator Tests")
struct BigOEstimatorTests {

    // MARK: - No loops = O(1)

    @Test("Function with no loops estimates O(1) high confidence")
    func noLoops() {
        let code = """
        func add(a: Int, b: Int) -> Int {
            return a + b
        }
        """
        let results = analyze(code)
        #expect(results[0].estimatedTimeComplexity == "O(1)")
        #expect(results[0].confidence == .high)
    }

    // MARK: - Single loop = O(n)

    @Test("Single for loop estimates O(n)")
    func singleForLoop() {
        let code = """
        func sum(items: [Int]) -> Int {
            var total = 0
            for item in items {
                total += item
            }
            return total
        }
        """
        let results = analyze(code)
        #expect(results[0].estimatedTimeComplexity == "O(n)")
        #expect(results[0].confidence == .high)
        #expect(results[0].complexityBasis.contains(.loopNesting(depth: 1)))
    }

    @Test("Single while loop estimates O(n)")
    func singleWhileLoop() {
        let code = """
        func drain(queue: inout [Int]) {
            while !queue.isEmpty {
                queue.removeFirst()
            }
        }
        """
        let results = analyze(code)
        #expect(results[0].estimatedTimeComplexity == "O(n)")
    }

    // MARK: - Nested loops = O(n²), O(n³)

    @Test("Two nested loops estimate O(n²)")
    func nestedLoops() {
        let code = """
        func pairs(items: [Int]) -> [(Int, Int)] {
            var result: [(Int, Int)] = []
            for i in items {
                for j in items {
                    result.append((i, j))
                }
            }
            return result
        }
        """
        let results = analyze(code)
        #expect(results[0].estimatedTimeComplexity == "O(n²)")
        #expect(results[0].complexityBasis.contains(.loopNesting(depth: 2)))
    }

    @Test("Three nested loops estimate O(n³)")
    func tripleNestedLoops() {
        let code = """
        func triples(items: [Int]) -> Int {
            var count = 0
            for _ in items {
                for _ in items {
                    for _ in items {
                        count += 1
                    }
                }
            }
            return count
        }
        """
        let results = analyze(code)
        #expect(results[0].estimatedTimeComplexity == "O(n³)")
        #expect(results[0].complexityBasis.contains(.loopNesting(depth: 3)))
    }

    // MARK: - Stdlib operation costs

    @Test("sort() in function body adds O(n log n)")
    func sortOperation() {
        let code = """
        func sortedItems(items: [Int]) -> [Int] {
            return items.sorted()
        }
        """
        let results = analyze(code)
        #expect(results[0].estimatedTimeComplexity == "O(n log n)")
        #expect(results[0].complexityBasis.contains(.stdlibOperation(name: "sorted", cost: "O(n log n)")))
    }

    @Test("contains inside a loop compounds to O(n²)")
    func containsInLoop() {
        let code = """
        func findCommon(a: [Int], b: [Int]) -> [Int] {
            var result: [Int] = []
            for item in a {
                if b.contains(item) {
                    result.append(item)
                }
            }
            return result
        }
        """
        let results = analyze(code)
        #expect(results[0].estimatedTimeComplexity == "O(n²)")
    }

    // MARK: - Confidence levels

    @Test("Function with only known operations has high confidence")
    func highConfidence() {
        let code = """
        func process(items: [Int]) -> [Int] {
            var result: [Int] = []
            for item in items {
                result.append(item * 2)
            }
            return result
        }
        """
        let results = analyze(code)
        #expect(results[0].confidence == .high)
    }

    @Test("RecursionClassification and low confidence are valid model values")
    func modelTypesExercised() {
        let basis: ComplexityBasis = .recursion(type: .linear)
        #expect(basis == .recursion(type: .linear))

        let classifications: [RecursionClassification] = [.linear, .divideConquer, .branching, .tail]
        #expect(classifications.count == 4)

        let confidence: EstimationConfidence = .low
        #expect(confidence == .low)
    }

    // MARK: - User-defined cost overlay

    @Test("User-defined costs override stdlib table")
    func userCostOverride() {
        let userCosts = ["DatabaseClient.fetch": "O(n)", "Cache.lookup": "O(1)"]
        let result = StdlibCostTable.cost(for: "DatabaseClient.fetch", userCosts: userCosts)
        #expect(result == "O(n)")
    }

    @Test("User costs fall through to built-in for unknown patterns")
    func userCostFallthrough() {
        let userCosts: [String: String] = [:]
        let result = StdlibCostTable.cost(for: "contains", userCosts: userCosts)
        #expect(result == "O(n)")
    }

    @Test("User costs match by suffix")
    func userCostSuffixMatch() {
        let userCosts = ["fetch": "O(n log n)"]
        let result = StdlibCostTable.cost(for: "DatabaseClient.fetch", userCosts: userCosts)
        #expect(result == "O(n log n)")
    }

    @Test("User costs propagate through BigOEstimator analysis")
    func userCostInAnalysis() {
        let code = """
        func loadData(client: DatabaseClient) {
            client.fetch()
        }
        """
        let analyzer = ComplexityAnalyzer()
        let records = analyzer.analyzeSource(
            code,
            userCosts: ["fetch": "O(n)"]
        )
        #expect(records[0].estimatedTimeComplexity == "O(n)")
    }

    @Test("User cost amplified inside loop")
    func userCostAmplifiedInLoop() {
        let code = """
        func loadAll(clients: [DatabaseClient]) {
            for client in clients {
                client.fetch()
            }
        }
        """
        let analyzer = ComplexityAnalyzer()
        let records = analyzer.analyzeSource(
            code,
            userCosts: ["fetch": "O(n)"]
        )
        #expect(records[0].estimatedTimeComplexity == "O(n²)")
    }

    // MARK: - Helpers

    private func analyze(_ source: String) -> [FunctionComplexityRecord] {
        let analyzer = ComplexityAnalyzer()
        return analyzer.analyzeSource(source)
    }
}
