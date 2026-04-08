import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

/// Cross-rule tests for the isolation context stack the visitor maintains.
/// These exercise the shared infra by observing how isolation-sensitive rules
/// fire (or don't) under nested type / extension scenarios.
@Suite("ConcurrencyAuditor: isolation context stack")
struct IsolationStackTests {

    // MARK: - Nested types

    @Test("Nested non-isolated class inside actor does NOT inherit actor isolation")
    func nestedClassDoesNotInheritIsolation() async throws {
        // Inner.f is a regular class method — DispatchQueue inside it should NOT fire
        // the dispatch-queue-in-actor rule, because Inner is not actor-isolated even
        // though it is lexically nested inside `actor A`.
        let code = """
        actor A {
            class Inner {
                func f() {
                    DispatchQueue.main.async {}
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "concurrency.dispatch-queue-in-actor" })
    }

    @Test("Nested actor inside class does push isolation for its own methods")
    func nestedActorPushesIsolation() async throws {
        let code = """
        class Outer {
            actor Inner {
                func f() {
                    DispatchQueue.main.async {}
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "concurrency.dispatch-queue-in-actor" })
    }

    // MARK: - Isolated extensions

    @Test("@MainActor extension propagates isolation to its members")
    func mainActorExtensionPropagates() async throws {
        let code = """
        struct Foo {}
        @MainActor
        extension Foo {
            func f() {
                DispatchQueue.main.async {}
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "concurrency.dispatch-queue-in-actor" })
    }

    @Test("Plain extension does not invent isolation")
    func plainExtensionStaysUnisolated() async throws {
        let code = """
        struct Foo {}
        extension Foo {
            func f() {
                DispatchQueue.main.async {}
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "concurrency.dispatch-queue-in-actor" })
    }

    // MARK: - Stack push/pop hygiene

    @Test("Sibling functions after a @MainActor function do not inherit isolation")
    func siblingFunctionsDoNotLeakIsolation() async throws {
        let code = """
        @MainActor
        func a() {
            DispatchQueue.main.async {}
        }

        func b() {
            DispatchQueue.main.async {}
        }
        """
        let result = try await TestHelpers.audit(code)
        let diags = result.diagnostics.filter { $0.ruleId == "concurrency.dispatch-queue-in-actor" }
        #expect(diags.count == 1, "Only the @MainActor function 'a' should fire, not 'b'")
    }
}
