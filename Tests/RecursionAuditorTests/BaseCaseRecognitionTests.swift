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

    @Test("A guard inside a nested closure counts as a base case")
    func guardInNestedClosureIsABaseCase() async throws {
        // swift-collections — `_subtracting_slow` reaches its guard through two nested
        // `read { }` closures. If the walker does not see it, every cycle containing
        // that function reads as unbounded.
        let code = """
        struct Node {
            func read<T>(_ body: (Int) -> T) -> T { body(0) }
            func slow(_ other: Node) -> Int {
                if other.flag {
                    return read { l in
                        other.read { r in
                            guard l == r else { return 0 }
                            return slow(other)
                        }
                    }
                }
                return slow(other)
            }
            var flag: Bool { true }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.unconditional-self-call" })
    }

    // MARK: - Cycles must see implicit returns too

    @Test("A cycle whose participant returns a literal implicitly is bounded")
    func cycleWithImplicitReturnBaseCase() async throws {
        // Ignite's MarkupElement: `is(_:)` ↔ `isType(_:)` descend through nested content and
        // terminate on `true` / `false` — branch values of an `if` expression, with no
        // `return` keyword anywhere. The strict cycle test only recognised `return <non-call>`,
        // so it saw no base case and called a plainly-terminating walk unbounded.
        let code = """
        struct Tree {
            var child: Tree? { nil }
            func isType(_ depth: Int) -> Bool {
                if depth == 0 {
                    true
                } else {
                    check(depth - 1)
                }
            }
            func check(_ depth: Int) -> Bool {
                isType(depth)
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    @Test("A cycle whose branches are all calls is still unbounded")
    func cycleWithoutBaseCaseStillFlagged() async throws {
        // The strictness that distinguishes a cycle from a self-call must survive: a branch
        // returning some *other* call may be handing off to the next participant.
        let code = """
        struct Spin {
            func alpha(_ n: Int) -> Int {
                if n > 0 { beta(n - 1) } else { beta(n + 1) }
            }
            func beta(_ n: Int) -> Int {
                alpha(n)
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    @Test("A cycle through computed properties can be bounded")
    func cycleThroughPropertiesCanBeBounded() async throws {
        // TCA's `availability` walk and GRDB's `isConstantInRequest` are cycles whose
        // participants are computed properties, and both terminate on `return nil`. Property
        // declarations reported `hasBaseCase: false` unconditionally — the strict answer was
        // never computed for them — so no participant could ever be marked bounded and every
        // such cycle read as unbounded.
        let code = """
        struct Wrapper {
            var inner: Wrapper? { nil }
            var availability: Wrapper? {
                if let inner {
                    return inner.attributes
                }
                return nil
            }
            var attributes: Wrapper? {
                availability
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.mutual-cycle" })
    }

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
