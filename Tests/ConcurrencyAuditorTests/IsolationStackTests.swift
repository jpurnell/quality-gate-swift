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

    // MARK: - A deinit's body has the deinit's isolation, not the type's

    private let taskRule = "concurrency.task-captures-self-no-isolation"
    private let dispatchRule = "concurrency.dispatch-queue-in-actor"

    @Test("A plain deinit body in a @MainActor class is nonisolated")
    func plainDeinitBodyIsNonisolated() async throws {
        // A Task spawned from a nonisolated deinit does not inherit the main actor, so
        // the Task rule — which reports deferred work inside an isolated context — has
        // nothing to say. (The deinit rule still reports the stored-state access.)
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {
                Task { self.x += 1 }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == taskRule }.count == 0)
    }

    @Test("An isolated deinit body in a @MainActor class is main-actor isolated")
    func isolatedDeinitBodyIsIsolated() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            isolated deinit {
                Task { self.x += 1 }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == taskRule }.count == 1)
    }

    @Test("A deinit attributed @MainActor has a main-actor body")
    func mainActorAttributedDeinitBodyIsIsolated() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            @MainActor deinit {
                DispatchQueue.main.async {}
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == dispatchRule }.count == 1)
    }

    @Test("A plain actor deinit is nonisolated; an isolated one is not")
    func actorDeinitIsolationFollowsTheModifier() async throws {
        let plain = """
        actor B {
            deinit {
                DispatchQueue.main.async {}
            }
        }
        """
        let plainResult = try await TestHelpers.audit(plain)
        #expect(plainResult.diagnostics.filter { $0.ruleId == dispatchRule }.count == 0)

        let isolated = """
        actor B {
            isolated deinit {
                DispatchQueue.main.async {}
            }
        }
        """
        let isolatedResult = try await TestHelpers.audit(isolated)
        #expect(isolatedResult.diagnostics.filter { $0.ruleId == dispatchRule }.count == 1)
    }
}
