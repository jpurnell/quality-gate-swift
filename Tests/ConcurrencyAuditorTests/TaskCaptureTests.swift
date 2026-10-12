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

    // MARK: - Optional-chained and force-unwrapped self
    //
    // `[weak self]` handles lifetime; the rule is about ordering. `self?.member` is the
    // same deferred access as `self.member`, so the two are judged alike.

    /// A `@MainActor` class with a stored, a computed, a synchronous and an `async`
    /// member, and one method `f` whose body is `body`.
    private func mainActorProbe(_ body: String) -> String {
        """
        final class Helper { func sync() {} }
        @MainActor
        final class A {
            var prop = 0
            var computed: Int {
                get { prop }
                set { prop = newValue }
            }
            func sync() {}
            func asyncMethod() async {}
            func f(other: Helper?) {
                \(body)
            }
        }
        """
    }

    private func flags(_ code: String) async throws -> Bool {
        try await TestHelpers.audit(code).diagnostics.contains { $0.ruleId == ruleId }
    }

    @Test("Flags a synchronous call through self? in a @MainActor class")
    func flagsOptionalChainedSyncCallInMainActorClass() async throws {
        #expect(try await flags(mainActorProbe("Task { [weak self] in self?.sync() }")))
    }

    @Test("Flags a write to a computed property through self?")
    func flagsOptionalChainedComputedPropertyWrite() async throws {
        // `computed` is not a stored property, so only the receiver can identify it.
        #expect(try await flags(mainActorProbe("Task { [weak self] in self?.computed = 2 }")))
    }

    @Test("An await on one statement does not clean a synchronous self? call beside it")
    func flagsOptionalChainedSyncCallBesideAnAwait() async throws {
        let body = """
        Task { [weak self] in
                    self?.sync()
                    await self?.asyncMethod()
                }
        """
        #expect(try await flags(mainActorProbe(body)))
    }

    @Test("Flags self? access in a @MainActor extension, where no property names are known")
    func flagsOptionalChainedAccessInMainActorExtension() async throws {
        let code = """
        @MainActor
        final class A {
            var prop = 0
        }
        @MainActor
        extension A {
            func g() {
                Task { [weak self] in self?.prop = 5 }
            }
        }
        """
        #expect(try await flags(code))
    }

    @Test("Flags a force-unwrapped self")
    func flagsForceUnwrappedSelf() async throws {
        #expect(try await flags(mainActorProbe("Task { [weak self] in self!.sync() }")))
    }

    @Test("Does not flag an awaited async method through self?")
    func ignoresAwaitedOptionalChainedAsyncMethod() async throws {
        #expect(try await !flags(mainActorProbe("Task { [weak self] in await self?.asyncMethod() }")))
    }

    @Test("Does not flag optional chaining on a receiver that is not self")
    func ignoresOptionalChainOnAnotherReceiver() async throws {
        // A captured parameter, and a local snapshot taken before the Task: a receiver
        // that is not `self` is the snapshot fix the rule recommends.
        #expect(try await !flags(mainActorProbe("Task { [weak other] in other?.sync() }")))
        let snapshot = """
        let snapshot = other
                Task { snapshot?.sync() }
        """
        #expect(try await !flags(mainActorProbe(snapshot)))
    }

    @Test("Does not flag self? in a class that is not isolated")
    func ignoresOptionalChainedSelfInNonIsolatedClass() async throws {
        let code = """
        class A {
            func sync() {}
            func f() {
                Task { [weak self] in self?.sync() }
            }
        }
        """
        #expect(try await !flags(code))
    }

    @Test("Does not look under an awaited MainActor.run")
    func ignoresOptionalChainedSelfInsideAwaitedMainActorRun() async throws {
        // The existing skip of everything under `await`. Recorded so that changing the
        // skip is a decision and not an accident.
        let body = "Task { [weak self] in await MainActor.run { self?.prop = 1 } }"
        #expect(try await !flags(mainActorProbe(body)))
    }

    @Test("Two self? accesses in one Task are one finding")
    func doesNotDoubleReport() async throws {
        let body = """
        Task { [weak self] in
                    self?.prop = 1
                    self?.sync()
                }
        """
        let result = try await TestHelpers.audit(mainActorProbe(body))
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 1)
    }

    @Test(
        "self. and self?. get the same verdict",
        arguments: [
            ("self.sync()", "self?.sync()"),
            ("self.prop = 1", "self?.prop = 1"),
            ("_ = self.computed", "_ = self?.computed"),
            ("await self.asyncMethod()", "await self?.asyncMethod()"),
        ]
    )
    func strongAndWeakSpellingsAgree(strong: String, weak: String) async throws {
        let strongVerdict = try await flags(mainActorProbe("Task { \(strong) }"))
        let weakVerdict = try await flags(mainActorProbe("Task { [weak self] in \(weak) }"))
        #expect(strongVerdict == weakVerdict)
    }
}
