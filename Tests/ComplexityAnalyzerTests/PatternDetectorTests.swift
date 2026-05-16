import Foundation
import Testing
@testable import ComplexityAnalyzer
@testable import QualityGateCore

@Suite("Pattern Detector Tests")
struct PatternDetectorTests {

    // MARK: - Contains in filter/loop

    @Test("Detects contains inside filter")
    func containsInFilter() {
        let code = """
        func common(a: [Int], b: [Int]) -> [Int] {
            return a.filter { b.contains($0) }
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(patterns.contains { pattern in
            if case .containsInFilter = pattern { return true }
            return false
        })
    }

    @Test("Detects contains inside for loop")
    func containsInForLoop() {
        let code = """
        func hasOverlap(a: [String], b: [String]) -> Bool {
            for item in a {
                if b.contains(item) {
                    return true
                }
            }
            return false
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(patterns.contains { pattern in
            if case .containsInFilter = pattern { return true }
            return false
        })
    }

    @Test("Does not flag contains on Set (O(1) lookup)")
    func containsOnSetIsOk() {
        let code = """
        func hasOverlap(a: [String], lookup: Set<String>) -> Bool {
            for item in a {
                if lookup.contains(item) {
                    return true
                }
            }
            return false
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(!patterns.contains { pattern in
            if case .containsInFilter = pattern { return true }
            return false
        })
    }

    // MARK: - Sort in loop

    @Test("Detects sorted() inside a loop")
    func sortInLoop() {
        let code = """
        func process(groups: [[Int]]) -> [[Int]] {
            var result: [[Int]] = []
            for group in groups {
                result.append(group.sorted())
            }
            return result
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(patterns.contains { pattern in
            if case .sortInLoop = pattern { return true }
            return false
        })
    }

    @Test("Does not flag sorted() outside a loop")
    func sortOutsideLoopIsOk() {
        let code = """
        func sortOnce(items: [Int]) -> [Int] {
            return items.sorted()
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(!patterns.contains { pattern in
            if case .sortInLoop = pattern { return true }
            return false
        })
    }

    // MARK: - Quadratic string concat

    @Test("Detects string += inside a loop")
    func quadraticStringConcat() {
        let code = """
        func build(words: [String]) -> String {
            var result = ""
            for word in words {
                result += word
            }
            return result
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(patterns.contains { pattern in
            if case .quadraticStringConcat = pattern { return true }
            return false
        })
    }

    @Test("Does not flag integer += inside a loop")
    func integerPlusEqualsIsOk() {
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
        let patterns = results[0].detectedPatterns
        #expect(!patterns.contains { pattern in
            if case .quadraticStringConcat = pattern { return true }
            return false
        })
    }

    // MARK: - String.contains false positive suppression

    @Test("Does not flag String.contains (substring check, not membership)")
    func stringContainsIsNotMembership() {
        let code = """
        func findMatches(items: [String], keyword: String) -> [String] {
            var result: [String] = []
            for item in items {
                if keyword.contains("test") {
                    result.append(item)
                }
            }
            return result
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(!patterns.contains { pattern in
            if case .containsInFilter = pattern { return true }
            return false
        })
    }

    @Test("Does not flag contains on locally declared Set variable")
    func containsOnDeclaredSetVariable() {
        let code = """
        func filter(items: [String], allowed: [String]) -> [String] {
            let allowedSet: Set<String> = Set(allowed)
            return items.filter { allowedSet.contains($0) }
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(!patterns.contains { pattern in
            if case .containsInFilter = pattern { return true }
            return false
        })
    }

    // MARK: - Suppression comments

    @Test("complexity-ok comment suppresses pattern detection")
    func suppressionComment() {
        let code = """
        func bounded(a: [Int], b: [Int]) -> [Int] {
            // complexity-ok: b is always <= 5 elements
            return a.filter { b.contains($0) }
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(!patterns.contains { pattern in
            if case .containsInFilter = pattern { return true }
            return false
        })
    }

    @Test("complexity-ok trailing comment on same line suppresses")
    func suppressionCommentSameLine() {
        let code = """
        func bounded(a: [Int], b: [Int]) -> [Int] {
            return a.filter { b.contains($0) } // complexity-ok: bounded
        }
        """
        let results = analyze(code)
        let patterns = results[0].detectedPatterns
        #expect(!patterns.contains { pattern in
            if case .containsInFilter = pattern { return true }
            return false
        })
    }

    // MARK: - No patterns in clean code

    @Test("Clean code has no patterns detected")
    func cleanCode() {
        let code = """
        func transform(items: [Int]) -> [Int] {
            return items.map { $0 * 2 }
        }
        """
        let results = analyze(code)
        #expect(results[0].detectedPatterns.isEmpty)
    }

    // MARK: - Helpers

    private func analyze(_ source: String) -> [FunctionComplexityRecord] {
        let analyzer = ComplexityAnalyzer()
        return analyzer.analyzeSource(source)
    }
}
