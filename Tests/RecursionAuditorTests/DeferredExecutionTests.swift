import Foundation
import Testing
@testable import RecursionAuditor
@testable import QualityGateCore

/// A reference handed to an executor runs on a different stack.
///
/// swift-nio's `isFulfilled` reads its own value inside `eventLoop.execute { … }` and
/// annotates the line: the closure runs later, on the event loop, where the other branch
/// is taken. The reference is real; the recursion is not.
///
/// The allowlist is deliberately narrow. Closure containment on its own is a bad proxy for
/// deferral — measured across the 22-package corpus, **93%** of closure-enclosed
/// self-references go to functions that run the closure immediately (`map`, `withLock`,
/// `withLockedValue`, `withCriticalRegion`). Demoting on containment alone would silence
/// `var x: Int { items.map { x }.count }`, which is genuine unbounded recursion. Naming the
/// executors instead fails in the safe direction: an unrecognized receiver keeps today's
/// behaviour, so an incomplete list costs precision and never recall.
@Suite("Deferred execution is not recursion")
struct DeferredExecutionTests {

    @Test("A self-reference inside an executor closure is not reported")
    func executorClosureIsNotRecursion() async throws {
        let code = """
        struct Future {
            var eventLoop: Loop
            var isFulfilled: Bool {
                if eventLoop.inEventLoop {
                    return true
                } else {
                    var result = false
                    eventLoop.execute {
                        result = self.isFulfilled
                    }
                    return result
                }
            }
        }
        """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A self-reference inside a synchronous closure is still reported")
    func synchronousClosureIsStillRecursion() async throws {
        // `map` runs its closure now, on this stack. This is the case the narrow allowlist
        // exists to keep reporting, and the reason containment alone was rejected.
        let code = """
        struct Counter {
            var items: [Int]
            var total: Int {
                items.map { _ in total }.count
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    @Test("A bare self-reference alongside a deferred one is still reported")
    func bareReferenceStillReported() async throws {
        // The demotion requires *every* reference to be deferred. One on the straight-line
        // path is enough to recurse.
        let code = """
        struct Thing {
            var loop: Loop
            var value: Int {
                let now = value
                loop.execute { _ = self.value }
                return now
            }
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "recursion.computed-property-self" })
    }

    private func audit(_ code: String) async throws -> CheckResult {
        let auditor = RecursionAuditor()
        let config = Configuration(recursion: RecursionAuditorConfig(useIndexStore: false))
        return try await auditor.auditSource(code, fileName: "test.swift", configuration: config)
    }
}
