import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

/// A base case is a path that returns without re-entering the function.
///
/// The original heuristic accepted `return <non-call>` and nothing else, so a function
/// whose every branch returns *some* call read as unbounded even when one of those
/// calls was a different function that plainly terminates the descent. Reduced from
/// GRDB's `SQLExpression.between(expression:lowerBound:upperBound:isNegated:)`.
@Suite("Base case recognition")
struct BaseCaseRecognitionTests {

    @Test("A branch returning a call to a different function is a base case")
    func returnOfNonRecursiveCallIsABaseCase() async throws {
        let code = """
        struct Expression {
            var isCollated = false
            static func wrap(_ value: Int) -> Expression { Expression() }

            static func between(lower: Int, upper: Int) -> Expression {
                if lower < 0 {
                    return wrap(between(lower: -lower, upper: upper).isCollated ? 1 : 0)
                } else {
                    return Expression.wrap(lower + upper)
                }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("A function whose every return is the recursive call still warns")
    func everyReturnRecursiveStillWarns() async throws {
        let code = """
        struct Loop {
            func descend(_ n: Int) -> Int {
                if n > 0 {
                    return descend(n - 1)
                } else {
                    return descend(n + 1)
                }
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("A literal return is still recognised as a base case")
    func literalReturnStillBaseCase() async throws {
        let code = """
        struct Fact {
            func compute(_ n: Int) -> Int {
                if n <= 1 { return 1 }
                return n * compute(n - 1)
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("A guard is still recognised as a base case")
    func guardStillBaseCase() async throws {
        let code = """
        struct Walk {
            func step(_ n: Int) -> Int {
                guard n > 0 else { return 0 }
                return step(n - 1)
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("An implicit-return branch with no recursive call is a base case")
    func implicitReturnBranchIsABaseCase() async throws {
        // Ignite — InlineElementCollection.swift:67. The terminating branches are
        // values of an `if` expression, so there is no `return` keyword for a
        // statement-shaped heuristic to find.
        let code = """
        struct Flattener {
            func flatten(_ content: Int) -> [Int] {
                if content > 10 {
                    flatten(content - 1)
                } else if content > 5 {
                    [content]
                } else {
                    []
                }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    @Test("A single-expression body that only recurses is still unbounded")
    func singleExpressionRecursionStillWarns() async throws {
        let code = """
        struct Spin {
            func go(_ n: Int) -> Int { go(n + 1) }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
