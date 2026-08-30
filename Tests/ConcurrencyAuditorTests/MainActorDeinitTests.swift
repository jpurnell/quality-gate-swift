import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: @MainActor deinit touches state")
struct MainActorDeinitTests {
    private let ruleId = "concurrency.main-actor-deinit-touches-state"

    // MARK: - Must flag

    @Test("Flags @MainActor class deinit reading stored property")
    func flagsRead() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {
                print(x)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags @MainActor class deinit assigning to stored property")
    func flagsWrite() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {
                x = 0
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags @MainActor class deinit referencing property in nested expression")
    func flagsNestedReference() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            func log(_ v: Int) {}
            deinit {
                log(x)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must not flag

    @Test("Does not flag empty deinit")
    func ignoresEmptyDeinit() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {}
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag deinit with no property reference")
    func ignoresPlainCleanup() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {
                print("cleanup")
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag deinit referencing only static property")
    func ignoresStaticReference() async throws {
        let code = """
        @MainActor
        class A {
            static let staticValue = 0
            var x = 0
            deinit {
                print(Self.staticValue)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag a deinit that touches only nonisolated(unsafe) state")
    func ignoresNonisolatedUnsafeProperty() async throws {
        // Without this the two rules contradict each other: `concurrency.task-no-deinit`
        // asks for a deinit that cancels a stored Task, and this rule forbids a deinit
        // that touches isolated state. `nonisolated(unsafe)` is what resolves it — the
        // property is declared outside the actor's isolation, so the deinit cannot trap.
        let code = """
        @MainActor
        final class A {
            // Justification: read and cancelled only in deinit.
            nonisolated(unsafe) private var task: Task<Void, Never>?
            deinit {
                task?.cancel()
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Still flags a deinit touching an ordinary isolated property")
    func flagsIsolatedPropertyAlongsideNonisolated() async throws {
        let code = """
        @MainActor
        final class A {
            // Justification: read and cancelled only in deinit.
            nonisolated(unsafe) private var task: Task<Void, Never>?
            var frameCount = 0
            deinit {
                task?.cancel()
                print(frameCount)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId },
                "frameCount is isolated state and is still read from deinit")
    }

    @Test("Does not flag deinit in non-MainActor class")
    func ignoresNonMainActorClass() async throws {
        let code = """
        class A {
            var x = 0
            deinit {
                print(x)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
