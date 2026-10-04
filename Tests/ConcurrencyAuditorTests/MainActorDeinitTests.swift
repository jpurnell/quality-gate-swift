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

    // MARK: - The deinit's own isolation (SE-0371)

    @Test("Does not flag an isolated deinit that cancels a stored Task")
    func acceptsIsolatedDeinitCancellingTask() async throws {
        let code = """
        @MainActor
        final class A {
            var task: Task<Void, Never>?
            isolated deinit {
                task?.cancel()
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 0)
    }

    @Test("Does not flag an isolated deinit that writes a stored property")
    func acceptsIsolatedDeinitWrite() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            isolated deinit {
                x = 0
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 0)
    }

    @Test("Does not flag an isolated deinit that mutates non-Sendable state")
    func acceptsIsolatedDeinitNonSendableState() async throws {
        // Non-Sendable state reachable from a stored property is exactly what
        // isolating the deinit makes safe.
        let code = """
        final class Counter { var n = 0 }
        @MainActor
        class A {
            var c = Counter()
            isolated deinit {
                c.n += 1
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 0)
    }

    @Test("Does not flag a deinit carrying its own @MainActor attribute")
    func acceptsMainActorAttributedDeinit() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            @MainActor deinit {
                print(x)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 0)
    }

    @Test("Attribute order and a second attribute on the class do not matter")
    func acceptsIsolatedDeinitWithSecondClassAttribute() async throws {
        let code = """
        @Observable @MainActor
        final class A {
            var task: Task<Void, Never>?
            var x = 0
            isolated deinit {
                task?.cancel()
                x = 0
            }
        }
        @MainActor @Observable
        final class B {
            var x = 0
            isolated deinit {
                x = 0
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 0)
    }

    @Test("Still flags an explicitly nonisolated deinit")
    func flagsNonisolatedDeinit() async throws {
        let code = """
        @MainActor
        final class A {
            var task: Task<Void, Never>?
            nonisolated deinit {
                task?.cancel()
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 1)
    }

    @Test("Still flags a plain deinit that cancels a stored Task")
    func flagsPlainDeinitCancellingTask() async throws {
        let code = """
        @MainActor
        final class A {
            var task: Task<Void, Never>?
            deinit {
                task?.cancel()
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 1)
    }

    @Test("Does not invent isolation for a nested class the type does not have")
    func nestedNonIsolatedClassIsNotThisRulesBusiness() async throws {
        // Inner is not @MainActor, so the rule never ran for it and still does not.
        // (The compiler rejects `isolated deinit` here; that is its finding to make.)
        let code = """
        @MainActor
        class Outer {
            class Inner {
                var x = 0
                isolated deinit {
                    print(x)
                }
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 0)
    }

    @Test("The word 'isolated' in a comment or string is not the modifier")
    func flagsPlainDeinitMentioningIsolatedInText() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            // isolated deinit
            deinit {
                print("isolated deinit", x)
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == ruleId }.count == 1)
    }

    // MARK: - Message and fix text

    @Test("The message does not claim a trap, and the fix names isolated deinit")
    func messageIsTrueAndFixIsSafe() async throws {
        let code = """
        @MainActor
        final class A {
            var task: Task<Void, Never>?
            deinit {
                task?.cancel()
            }
        }
        """
        let result = try await TestHelpers.audit(code)
        let flagged = result.diagnostics.filter { $0.ruleId == ruleId }
        #expect(flagged.count == 1)
        #expect(flagged.first?.message.contains("trap") == false)
        #expect(flagged.first?.message.contains("race") == true)
        #expect(flagged.first?.suggestedFix?.contains("isolated deinit") == true)
    }

    // MARK: - A name is the property only when nothing nearer binds it

    private func flaggedCount(_ code: String) async throws -> Int {
        try await TestHelpers.audit(code).diagnostics.filter { $0.ruleId == ruleId }.count
    }

    @Test("A local in the deinit named like a property is the local")
    func ignoresLocalShadowInDeinit() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {
                let x = 1
                print(x)
            }
        }
        """
        #expect(try await flaggedCount(code) == 0)
    }

    @Test("A member of another value named like a property is that value's")
    func ignoresMemberOfOtherBaseInDeinit() async throws {
        let code = """
        enum Registry { static var x = 0 }
        @MainActor
        class A {
            var x = 0
            deinit {
                print(Registry.x)
            }
        }
        """
        #expect(try await flaggedCount(code) == 0)
    }

    @Test("A closure parameter in the deinit named like a property is the parameter")
    func ignoresClosureParameterInDeinit() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {
                [1, 2].forEach { x in print(x) }
            }
        }
        """
        #expect(try await flaggedCount(code) == 0)
    }

    @Test("self.property is the property, whatever local shares its name")
    func flagsSelfMemberDespiteLocalInDeinit() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {
                let x = 1
                print(self.x, x)
            }
        }
        """
        #expect(try await flaggedCount(code) == 1)
    }

    @Test("A read before a later local of the same name is the property")
    func flagsReadBeforeLaterShadowInDeinit() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            deinit {
                print(x)
                let x = 1
                print(x)
            }
        }
        """
        #expect(try await flaggedCount(code) == 1)
    }

    @Test("A property used as the base of another member is the state touched")
    func flagsPropertyAsBaseInDeinit() async throws {
        let code = """
        @MainActor
        class A {
            var task: Task<Void, Never>?
            deinit {
                task?.cancel()
            }
        }
        """
        #expect(try await flaggedCount(code) == 1)
    }

    @Test("A method called through self is not stored state")
    func ignoresSelfMethodNamedUnlikeAnyProperty() async throws {
        // Calling an isolated method from a nonisolated deinit is the compiler's to
        // reject. This rule reads storage.
        let code = """
        @MainActor
        class A {
            var x = 0
            nonisolated func log() {}
            deinit {
                self.log()
            }
        }
        """
        #expect(try await flaggedCount(code) == 0)
    }
}
