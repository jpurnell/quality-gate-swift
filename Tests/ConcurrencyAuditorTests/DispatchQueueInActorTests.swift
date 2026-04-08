import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: DispatchQueue inside actor isolation")
struct DispatchQueueInActorTests {
    private let ruleId = "concurrency.dispatch-queue-in-actor"

    // MARK: - Must flag

    @Test("Flags DispatchQueue.main.async in @MainActor function")
    func flagsInMainActorFunc() async throws {
        let code = """
        @MainActor
        func f() {
            DispatchQueue.main.async {
                print("hi")
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags DispatchQueue.main.async inside actor")
    func flagsInActor() async throws {
        let code = """
        actor A {
            func f() {
                DispatchQueue.main.async {}
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags DispatchQueue.global().async inside actor")
    func flagsGlobalQueueInActor() async throws {
        let code = """
        actor A {
            func f() {
                DispatchQueue.global().async {}
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must not flag

    @Test("Does not flag DispatchQueue at top level (no isolation)")
    func ignoresTopLevel() async throws {
        let code = """
        func f() {
            DispatchQueue.main.async {}
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag DispatchQueue inside non-isolated class")
    func ignoresNonIsolatedClass() async throws {
        let code = """
        class A {
            func f() {
                DispatchQueue.main.async {}
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
