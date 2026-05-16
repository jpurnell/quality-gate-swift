import Foundation
import Testing
@testable import ComplexityAnalyzer
@testable import QualityGateCore

@Suite("CognitiveComplexity Tests")
struct CognitiveComplexityTests {

    // MARK: - Identity

    @Test("ComplexityAnalyzer has correct id and name")
    func checkerIdentity() {
        let analyzer = ComplexityAnalyzer()
        #expect(analyzer.id == "complexity")
        #expect(analyzer.name == "Complexity Analyzer")
    }

    // MARK: - Trivial functions (score 0)

    @Test("Empty function has complexity 0")
    func emptyFunction() {
        let code = """
        func doNothing() {}
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 0)
        #expect(results[0].cognitiveBreakdown.isEmpty)
    }

    @Test("Linear function with no branches has complexity 0")
    func linearFunction() {
        let code = """
        func compute(x: Int, y: Int) -> Int {
            let sum = x + y
            let product = x * y
            return sum + product
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 0)
    }

    // MARK: - Simple flow breaks (+1 each)

    @Test("Single if adds +1")
    func singleIf() {
        let code = """
        func check(x: Int) -> Bool {
            if x > 0 {
                return true
            }
            return false
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 1)
    }

    @Test("If-else adds +1 for if, +1 for else")
    func ifElse() {
        let code = """
        func check(x: Int) -> String {
            if x > 0 {
                return "positive"
            } else {
                return "non-positive"
            }
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 2)
    }

    @Test("Else-if adds +1 (not nested)")
    func elseIf() {
        let code = """
        func classify(x: Int) -> String {
            if x > 0 {
                return "positive"
            } else if x < 0 {
                return "negative"
            } else {
                return "zero"
            }
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        // if: +1, else if: +1, else: +1 = 3
        #expect(results[0].cognitiveComplexity == 3)
    }

    @Test("For loop adds +1")
    func forLoop() {
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
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 1)
    }

    @Test("While loop adds +1")
    func whileLoop() {
        let code = """
        func countdown(from n: Int) {
            var i = n
            while i > 0 {
                i -= 1
            }
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 1)
    }

    @Test("Repeat-while adds +1")
    func repeatWhile() {
        let code = """
        func readUntilDone() {
            var done = false
            repeat {
                done = true
            } while !done
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 1)
    }

    @Test("Guard-else adds +1")
    func guardElse() {
        let code = """
        func process(value: Int?) -> Int {
            guard let v = value else {
                return 0
            }
            return v * 2
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 1)
    }

    @Test("Switch adds +1")
    func switchStatement() {
        let code = """
        func describe(x: Int) -> String {
            switch x {
            case 0: return "zero"
            case 1: return "one"
            default: return "other"
            }
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 1)
    }

    @Test("Catch clause adds +1")
    func catchClause() {
        let code = """
        func load() -> String {
            do {
                let data = try readFile()
                return data
            } catch {
                return "default"
            }
        }
        func readFile() throws -> String { "" }
        """
        let results = analyze(code)
        #expect(results[0].cognitiveComplexity == 1)
    }

    // MARK: - Nesting increments

    @Test("If inside for adds nesting increment")
    func ifInsideFor() {
        let code = """
        func filter(items: [Int]) -> [Int] {
            var result: [Int] = []
            for item in items {
                if item > 0 {
                    result.append(item)
                }
            }
            return result
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        // for: +1 (nesting 0), if: +1 base + 1 nesting = +2 → total 3
        #expect(results[0].cognitiveComplexity == 3)
    }

    @Test("Deeply nested structure compounds nesting")
    func deepNesting() {
        let code = """
        func deep(items: [[Int]]) -> Int {
            var count = 0
            for group in items {
                for item in group {
                    if item > 0 {
                        if item < 100 {
                            count += 1
                        }
                    }
                }
            }
            return count
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        // for: +1 (nest 0)
        // for: +1 +1 (nest 1) = +2
        // if: +1 +2 (nest 2) = +3
        // if: +1 +3 (nest 3) = +4
        // total = 1 + 2 + 3 + 4 = 10
        #expect(results[0].cognitiveComplexity == 10)
    }

    @Test("Guard at top level does not compound nesting for subsequent code")
    func guardDoesNotNest() {
        let code = """
        func process(value: Int?) -> Int {
            guard let v = value else {
                return 0
            }
            if v > 10 {
                return v
            }
            return v * 2
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        // guard: +1 (nest 0), if: +1 (nest 0) → total 2
        #expect(results[0].cognitiveComplexity == 2)
    }

    // MARK: - Logical operators

    @Test("Logical operator sequence adds +1")
    func logicalOperatorSequence() {
        let code = """
        func check(a: Bool, b: Bool, c: Bool) -> Bool {
            if a && b && c {
                return true
            }
            return false
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        // if: +1, &&-sequence: +1 → total 2
        #expect(results[0].cognitiveComplexity == 2)
    }

    @Test("Mixed logical operators add per sequence change")
    func mixedLogicalOperators() {
        let code = """
        func check(a: Bool, b: Bool, c: Bool) -> Bool {
            if a && b || c {
                return true
            }
            return false
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        // if: +1, && sequence: +1, || sequence: +1 → total 3
        #expect(results[0].cognitiveComplexity == 3)
    }

    // MARK: - Multiple functions

    @Test("Multiple functions scored independently")
    func multipleFunctions() {
        let code = """
        func simple() -> Int { return 1 }
        func moderate(x: Int) -> Int {
            if x > 0 {
                return x
            }
            return -x
        }
        """
        let results = analyze(code)
        #expect(results.count == 2)
        #expect(results[0].functionName == "simple")
        #expect(results[0].cognitiveComplexity == 0)
        #expect(results[1].functionName == "moderate")
        #expect(results[1].cognitiveComplexity == 1)
    }

    // MARK: - Worked example from proposal

    @Test("Worked example from scoring guide")
    func workedExample() throws {
        let code = """
        func example(items: [Item]) {
            for item in items {
                if item.isValid {
                    guard let x = item.value else {
                        continue
                    }
                    _ = x
                }
            }
        }
        struct Item { var isValid: Bool; var value: Int? }
        """
        let results = analyze(code)
        let example = try #require(results.first { $0.functionName == "example" })
        // for: +1 (nest 0)
        // if: +1 +1 (nest 1) = +2
        // guard: +1 +2 (nest 2) = +3
        // total = 6
        #expect(example.cognitiveComplexity == 6)
    }

    // MARK: - Breakdown tracking

    @Test("Breakdown records each increment with correct values")
    func breakdownTracking() {
        let code = """
        func check(items: [Int]) {
            for item in items {
                if item > 0 {
                    print(item)
                }
            }
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        let breakdown = results[0].cognitiveBreakdown
        #expect(breakdown.count == 2)

        #expect(breakdown[0].node == "for")
        #expect(breakdown[0].baseIncrement == 1)
        #expect(breakdown[0].nestingIncrement == 0)

        #expect(breakdown[1].node == "if")
        #expect(breakdown[1].baseIncrement == 1)
        #expect(breakdown[1].nestingIncrement == 1)
    }

    // MARK: - Metadata

    @Test("Records function name, file path, module, and line range")
    func metadata() {
        let code = """
        func hello() {
            print("hi")
        }
        """
        let results = CognitiveComplexityVisitor.analyze(
            source: code,
            filePath: "/path/to/file.swift",
            moduleName: "MyModule"
        )
        #expect(results.count == 1)
        #expect(results[0].functionName == "hello")
        #expect(results[0].filePath == "/path/to/file.swift")
        #expect(results[0].moduleName == "MyModule")
        #expect(results[0].startLine == 1)
        #expect(results[0].endLine == 3)
    }

    // MARK: - Advisory behavior

    @Test("Check always returns passed status regardless of complexity")
    func alwaysPasses() async throws {
        let analyzer = ComplexityAnalyzer()
        let config = Configuration()
        let result = try await analyzer.check(configuration: config)
        #expect(result.status == .passed)
    }

    // MARK: - Ternary and nil-coalescing

    @Test("Ternary operator adds +1")
    func ternaryOperator() {
        let code = """
        func pick(flag: Bool) -> Int {
            return flag ? 1 : 0
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 1)
    }

    @Test("Nil-coalescing adds +1")
    func nilCoalescing() {
        let code = """
        func value(opt: Int?) -> Int {
            return opt ?? 0
        }
        """
        let results = analyze(code)
        #expect(results.count == 1)
        #expect(results[0].cognitiveComplexity == 1)
    }

    // MARK: - Helpers

    private func analyze(_ source: String) -> [FunctionComplexityRecord] {
        let analyzer = ComplexityAnalyzer()
        return analyzer.analyzeSource(source)
    }
}
