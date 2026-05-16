import Foundation
import Testing
@testable import ComplexityAnalyzer
@testable import QualityGateCore

@Suite("CallGraph Amplifier Tests")
struct CallGraphAmplifierTests {

    // MARK: - Basic amplification

    @Test("Call to O(n) function inside loop amplifies caller to O(n²)")
    func linearCalleeInLoop() throws {
        let code = """
        func linearSearch(items: [Int], target: Int) -> Bool {
            for item in items {
                if item == target { return true }
            }
            return false
        }

        func quadratic(items: [Int], targets: [Int]) -> [Bool] {
            var results: [Bool] = []
            for target in targets {
                results.append(linearSearch(items: items, target: target))
            }
            return results
        }
        """
        let records = analyzeWithAmplification(code)
        let quadratic = try #require(records.first { $0.functionName == "quadratic" })
        #expect(quadratic.estimatedTimeComplexity == "O(n²)")
        #expect(quadratic.complexityBasis.contains { basis in
            if case .callGraphAmplification(let callee, _) = basis {
                return callee == "linearSearch"
            }
            return false
        })
    }

    @Test("Call to O(n) function outside loop does not amplify")
    func linearCalleeOutsideLoop() throws {
        let code = """
        func linearWork(items: [Int]) -> Int {
            var sum = 0
            for item in items {
                sum += item
            }
            return sum
        }

        func caller(items: [Int]) -> Int {
            return linearWork(items: items)
        }
        """
        let records = analyzeWithAmplification(code)
        let caller = try #require(records.first { $0.functionName == "caller" })
        #expect(caller.estimatedTimeComplexity == "O(n)")
    }

    @Test("Call to O(1) function inside loop stays O(n)")
    func constantCalleeInLoop() throws {
        let code = """
        func constantOp() -> Int { return 42 }

        func looper(n: Int) -> Int {
            var sum = 0
            for i in 0..<n {
                sum += constantOp()
            }
            return sum
        }
        """
        let records = analyzeWithAmplification(code)
        let looper = try #require(records.first { $0.functionName == "looper" })
        #expect(looper.estimatedTimeComplexity == "O(n)")
    }

    @Test("Call to O(n log n) function inside loop amplifies to O(n² log n)")
    func sortCalleeInLoop() throws {
        let code = """
        func sortItems(items: [Int]) -> [Int] {
            return items.sorted()
        }

        func sortEach(groups: [[Int]]) -> [[Int]] {
            var results: [[Int]] = []
            for group in groups {
                results.append(sortItems(items: group))
            }
            return results
        }
        """
        let records = analyzeWithAmplification(code)
        let sortEach = try #require(records.first { $0.functionName == "sortEach" })
        #expect(sortEach.estimatedTimeComplexity == "O(n² log n)")
    }

    // MARK: - Depth limiting

    @Test("Amplification respects max depth of 1 by default")
    func depthLimitPreventsTransitiveAmplification() throws {
        let code = """
        func leaf(items: [Int]) -> Int {
            var sum = 0
            for item in items { sum += item }
            return sum
        }

        func middle(items: [Int]) -> Int {
            var total = 0
            for _ in items { total += leaf(items: items) }
            return total
        }

        func top(items: [Int]) -> Int {
            var result = 0
            for _ in items { result += middle(items: items) }
            return result
        }
        """
        let records = analyzeWithAmplification(code, maxDepth: 1)
        let top = try #require(records.first { $0.functionName == "top" })
        #expect(top.estimatedTimeComplexity == "O(n²)")
    }

    @Test("Amplification with max depth 2 sees transitive costs")
    func depth2SeesTransitive() throws {
        let code = """
        func leaf(items: [Int]) -> Int {
            var sum = 0
            for item in items { sum += item }
            return sum
        }

        func middle(items: [Int]) -> Int {
            var total = 0
            for _ in items { total += leaf(items: items) }
            return total
        }

        func top(items: [Int]) -> Int {
            var result = 0
            for _ in items { result += middle(items: items) }
            return result
        }
        """
        let records = analyzeWithAmplification(code, maxDepth: 2)
        let top = try #require(records.first { $0.functionName == "top" })
        #expect(top.estimatedTimeComplexity == "O(n³)")
    }

    // MARK: - Helpers

    private func analyzeWithAmplification(_ source: String, maxDepth: Int = 1) -> [FunctionComplexityRecord] {
        CallGraphAmplifier.analyze(source: source, moduleName: "Test", maxDepth: maxDepth)
    }
}
