import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

/// A member that says it is not isolated is not isolated: `nonisolated`, and a `static`
/// member of an actor. A member of a global-actor type that says nothing is.
@Suite("ConcurrencyAuditor: member-level isolation")
struct MemberIsolationTests {
    private let taskRule = "concurrency.task-captures-self-no-isolation"
    private let dispatchRule = "concurrency.dispatch-queue-in-actor"

    private func count(_ rule: String, in code: String) async throws -> Int {
        try await TestHelpers.audit(code).diagnostics.filter { $0.ruleId == rule }.count
    }

    // MARK: - Must not flag

    @Test("A nonisolated func of a @MainActor class is not isolated")
    func ignoresNonisolatedFuncInPrimaryDeclaration() async throws {
        let code = """
        @MainActor
        class A {
            nonisolated func f() {
                DispatchQueue.main.async {}
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A nonisolated computed property of a @MainActor class is not isolated")
    func ignoresNonisolatedComputedPropertyInPrimaryDeclaration() async throws {
        let code = """
        @MainActor
        class A: CustomStringConvertible {
            nonisolated var description: String {
                DispatchQueue.main.async {}
                return ""
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A nonisolated subscript of an actor is not isolated")
    func ignoresNonisolatedSubscript() async throws {
        let code = """
        actor Act {
            nonisolated subscript(index: Int) -> Int {
                DispatchQueue.global().async {}
                return index
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A static member of an actor is not isolated")
    func ignoresStaticMemberOfActor() async throws {
        let code = """
        actor Act {
            static func s() {
                DispatchQueue.global().async {}
            }
            static var shared: Int {
                DispatchQueue.global().async {}
                return 0
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A nonisolated init of an actor is not isolated")
    func ignoresNonisolatedInit() async throws {
        let code = """
        actor Act {
            nonisolated init(queue: Int) {
                DispatchQueue.global().async {}
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A plain Task in a nonisolated member is not in an isolated context")
    func ignoresPlainTaskInNonisolatedMember() async throws {
        let code = """
        @MainActor
        class A {
            var x = 0
            func bump() { x += 1 }
            nonisolated func cb() {
                Task { await self.bump() }
            }
        }
        """
        #expect(try await count(taskRule, in: code) == 0)
    }

    @Test("A nonisolated func in an extension of a @MainActor class is not isolated")
    func ignoresNonisolatedFuncInExtension() async throws {
        let code = """
        @MainActor
        class A { var x = 0 }
        extension A {
            nonisolated func f() {
                DispatchQueue.main.async {}
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A nonisolated computed property in a conformance extension is not isolated")
    func ignoresNonisolatedComputedPropertyInExtension() async throws {
        let code = """
        @MainActor
        class A { var x = 0 }
        extension A: CustomStringConvertible {
            nonisolated var description: String {
                DispatchQueue.main.async {}
                return ""
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A static member in an extension of an actor is not isolated")
    func ignoresStaticMemberOfActorExtension() async throws {
        let code = """
        actor Act { var c = 0 }
        extension Act {
            static func s() {
                DispatchQueue.global().async {}
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    @Test("A nonisolated extension is not isolated")
    func ignoresNonisolatedExtension() async throws {
        let code = """
        @MainActor
        class A { var x = 0 }
        nonisolated extension A {
            func f() {
                DispatchQueue.main.async {}
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 0)
    }

    // MARK: - Must flag

    @Test("A static member of a @MainActor type is isolated")
    func flagsStaticMemberOfMainActorType() async throws {
        let code = """
        @MainActor
        class A {
            static func s() {
                DispatchQueue.main.async {}
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 1)
    }

    @Test("A @MainActor member of a plain type is isolated, whatever kind of member")
    func flagsMainActorMembersOfPlainType() async throws {
        let code = """
        class A {
            @MainActor func f() {
                DispatchQueue.main.async {}
            }
            @MainActor var value: Int {
                DispatchQueue.main.async {}
                return 0
            }
            @MainActor init() {
                DispatchQueue.main.async {}
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 3)
    }

    @Test("A sibling after a nonisolated member is isolated again")
    func siblingAfterNonisolatedMemberIsIsolated() async throws {
        let code = """
        @MainActor
        class A {
            nonisolated var first: Int {
                DispatchQueue.main.async {}
                return 0
            }
            var second: Int {
                DispatchQueue.main.async {}
                return 0
            }
        }
        """
        #expect(try await count(dispatchRule, in: code) == 1)
    }

    @Test("A @MainActor Task in a nonisolated member of a @MainActor type is still flagged")
    func flagsMainActorHopInNonisolatedMemberOfMainActorType() async throws {
        // The member is not isolated; the closure is, and the state it touches belongs
        // to a main-actor type. That is the rule's subject.
        let code = """
        @MainActor
        class A {
            var x = 0
            nonisolated func cb() {
                Task { @MainActor in self.x = 1 }
            }
        }
        """
        #expect(try await count(taskRule, in: code) == 1)
    }

    @Test("A @MainActor Task in a nonisolated member of a plain type is not flagged")
    func ignoresMainActorHopInPlainType() async throws {
        let code = """
        class A {
            var x = 0
            func cb() {
                Task { @MainActor in self.x = 1 }
            }
        }
        """
        #expect(try await count(taskRule, in: code) == 0)
    }
}
