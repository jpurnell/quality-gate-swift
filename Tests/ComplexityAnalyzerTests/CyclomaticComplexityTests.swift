import Foundation
import Testing
import QualityGateCore
@testable import ComplexityAnalyzer

/// Cyclomatic complexity, recorded alongside cognitive complexity rather than instead of it.
///
/// ## Why both
///
/// The erosion metric (`ARatioNeedsAPopulation.md` in the companion) is defined over
/// `CC(f) > 10`, which is a *cyclomatic* convention with a literature and an established
/// threshold behind it. This repository measured only cognitive complexity, whose scale is not
/// the same and whose threshold is configurable — so the post's figures could not be compared
/// to anything here, and a locally-invented threshold would have been a number with no
/// provenance.
///
/// Keeping both is not redundancy. They disagree in a specific and informative way: cognitive
/// complexity charges for *nesting* and cyclomatic does not, so a wide gap between them marks
/// deeply nested code rather than merely branchy code. The tests below pin that difference
/// rather than leaving it to be rediscovered.
///
/// ## What counts, and why these choices
///
/// A decision point is one that creates an alternative path: `if` (an `else if` is a nested
/// `if`, so it counts; a bare `else` creates no new decision), `for`, `while`, `repeat`,
/// `guard`, each `case` of a switch, each `catch` clause, `?:`, `&&`, `||`, and `??`.
///
/// Deliberately *not* counted:
/// - **the `switch` itself** — its cases are the decisions, and counting both double-charges.
///   This is where cognitive and cyclomatic diverge most: cognitive charges +1 for the switch
///   and nothing per case.
/// - **`do`** — entering a `do` block branches nowhere. Its `catch` clauses do.
@Suite("Cyclomatic complexity")
struct CyclomaticComplexityTests {

    private func complexity(of source: String) -> Int? {
        ComplexityAnalyzer().analyzeSource(source).first?.cyclomaticComplexity
    }

    // MARK: - The base path

    @Test("A straight-line function has complexity 1")
    func straightLineIsOne() {
        #expect(complexity(of: "func f() { let a = 1; print(a) }") == 1)
    }

    // MARK: - Branching constructs

    @Test("One if adds one")
    func singleIf() {
        #expect(complexity(of: "func f(_ a: Int) { if a > 0 { print(a) } }") == 2)
    }

    @Test("A bare else adds nothing — it introduces no new decision")
    func elseAddsNothing() {
        let source = "func f(_ a: Int) { if a > 0 { print(a) } else { print(-a) } }"
        #expect(complexity(of: source) == 2)
    }

    @Test("An else-if is a nested if, and does add one")
    func elseIfAddsOne() {
        let source = """
        func f(_ a: Int) {
            if a > 0 { print(a) } else if a < 0 { print(-a) } else { print(0) }
        }
        """
        #expect(complexity(of: source) == 3)
    }

    @Test("A guard adds one")
    func guardAddsOne() {
        #expect(complexity(of: "func f(_ a: Int?) { guard let a else { return }; print(a) }") == 2)
    }

    @Test("Loops each add one")
    func loopsAddOne() {
        #expect(complexity(of: "func f(_ xs: [Int]) { for x in xs { print(x) } }") == 2)
        #expect(complexity(of: "func f(_ n: Int) { var i = 0; while i < n { i += 1 } }") == 2)
        #expect(complexity(of: "func f(_ n: Int) { var i = 0; repeat { i += 1 } while i < n }") == 2)
    }

    @Test("A ternary adds one")
    func ternaryAddsOne() {
        #expect(complexity(of: "func f(_ a: Int) -> Int { a > 0 ? a : -a }") == 2)
    }

    @Test("Each logical operator adds one")
    func logicalOperatorsAddOne() {
        #expect(complexity(of: "func f(_ a: Int, _ b: Int) -> Bool { a > 0 && b > 0 }") == 2)
        #expect(complexity(of: "func f(_ a: Int, _ b: Int, _ c: Int) -> Bool { a > 0 && b > 0 || c > 0 }") == 3)
    }

    @Test("Nil-coalescing adds one — it selects between two paths")
    func nilCoalescingAddsOne() {
        #expect(complexity(of: "func f(_ a: Int?) -> Int { a ?? 0 }") == 2)
    }

    // MARK: - Switch: the cases are the decisions, not the switch

    @Test("A switch charges per case, not for the switch itself")
    func switchChargesPerCase() {
        let source = """
        func f(_ a: Int) -> String {
            switch a {
            case 0: return "zero"
            case 1: return "one"
            case 2: return "two"
            default: return "many"
            }
        }
        """
        // 1 base + 3 cases. `default` is the fall-through path, not a decision.
        #expect(complexity(of: source) == 4)
    }

    // MARK: - do/catch

    @Test("A do block adds nothing; each catch adds one")
    func doAddsNothingCatchAddsOne() {
        let source = """
        func f() {
            do {
                try risky()
            } catch is CancellationError {
                print("cancelled")
            } catch {
                print("other")
            }
        }
        """
        #expect(complexity(of: source) == 3)
    }

    // MARK: - The difference from cognitive complexity

    @Test("Nesting does not change cyclomatic complexity, but does change cognitive")
    func nestingSeparatesTheTwoMetrics() {
        let flat = """
        func f(_ a: Int, _ b: Int, _ c: Int) {
            if a > 0 { print(a) }
            if b > 0 { print(b) }
            if c > 0 { print(c) }
        }
        """
        let nested = """
        func f(_ a: Int, _ b: Int, _ c: Int) {
            if a > 0 {
                if b > 0 {
                    if c > 0 { print(c) }
                }
            }
        }
        """
        guard let flatRecord = ComplexityAnalyzer().analyzeSource(flat).first,
              let nestedRecord = ComplexityAnalyzer().analyzeSource(nested).first else {
            Issue.record("expected one record from each fixture")
            return
        }

        // Three decisions either way.
        #expect(flatRecord.cyclomaticComplexity == 4)
        #expect(nestedRecord.cyclomaticComplexity == 4)

        // Cognitive charges for depth, which is the whole reason to keep both.
        #expect(nestedRecord.cognitiveComplexity > flatRecord.cognitiveComplexity)
    }

    // MARK: - Invariants

    @Test("Cyclomatic complexity is never below 1, even for an empty body")
    func neverBelowOne() {
        #expect(complexity(of: "func f() {}") == 1)
    }

    @Test("An initializer is measured like any other function")
    func initializersAreMeasured() {
        let source = """
        struct S {
            init(_ a: Int) {
                if a > 0 { print(a) }
            }
        }
        """
        #expect(complexity(of: source) == 2)
    }
}
