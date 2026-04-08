import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: Task captures self without isolation")
struct TaskCaptureTests {
    private let ruleId = "concurrency.task-captures-self-no-isolation"

    // MARK: - Must flag

    @Test("Flags Task in actor capturing self implicitly")
    func flagsImplicitSelfInActor() async throws {
        let code = """
        actor A {
            var x = 0
            func f() {
                Task {
                    x += 1
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags Task in actor capturing explicit self")
    func flagsExplicitSelfInActor() async throws {
        let code = """
        actor A {
            var x = 0
            func f() {
                Task {
                    self.x += 1
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags nested Task capturing self")
    func flagsNestedTask() async throws {
        let code = """
        actor A {
            var x = 0
            func f() {
                Task {
                    Task {
                        self.x += 1
                    }
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags Task capturing self inside @MainActor class")
    func flagsTaskInMainActorClass() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            func f() {
                Task {
                    self.x += 1
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must not flag

    @Test("Does not flag Task with explicit await isolation hop")
    func ignoresAwaitedSelfMethod() async throws {
        let code = """
        actor A {
            var x = 0
            func bump() { x += 1 }
            func f() {
                Task {
                    await self.bump()
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag Task in non-isolated class")
    func ignoresNonActorClass() async throws {
        let code = """
        class A {
            func f() {
                Task {
                    print("hi")
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag withTaskGroup")
    func ignoresWithTaskGroup() async throws {
        let code = """
        actor A {
            var x = 0
            func f() async {
                await withTaskGroup(of: Int.self) { group in
                    self.x += 1
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag async let")
    func ignoresAsyncLet() async throws {
        let code = """
        actor A {
            func f() async -> Int {
                async let x = compute()
                return await x
            }
            func compute() async -> Int { 0 }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
