import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

/// The Task rule reports a name only when it resolves to the actor's stored property.
/// A capture-list entry, a parameter, a local, or an `if let` / `guard let` / `for` /
/// `case let` binding of the same spelling is that binding; a member reached through
/// another base belongs to that base.
@Suite("ConcurrencyAuditor: a shadow is not the property")
struct TaskCaptureBindingTests {
    private let ruleId = "concurrency.task-captures-self-no-isolation"

    /// A `@MainActor` class with stored `device`, `log`, `coherence` and `count`, and
    /// the members under test.
    private func shapes(_ members: String) -> String {
        """
        struct Logger { func info(_ message: String) {} }
        enum AppLog { static let device = Logger() }
        struct Peer { let device: String }
        @MainActor
        final class Shapes {
            var device: String? = "glasses"
            let log = Logger()
            var coherence = 0.0
            var count = 0
            func bump() { count += 1 }
            \(members)
        }
        """
    }

    private func flagged(_ members: String) async throws -> Int {
        try await TestHelpers.audit(shapes(members)).diagnostics.filter { $0.ruleId == ruleId }.count
    }

    // MARK: - Must not flag: the name is bound to something else

    @Test("A capture-list entry named like a property is the capture")
    func ignoresCaptureListEntryNamedLikeProperty() async throws {
        #expect(try await flagged(#"func f() { Task { [log] in log.info("x") } }"#) == 0)
    }

    @Test("A capture-list initializer is read when the closure is created")
    func ignoresCaptureListInitializer() async throws {
        #expect(try await flagged(#"func f() { Task { [log = self.log] in log.info("x") } }"#) == 0)
    }

    @Test("A local bound before the Task is the local")
    func ignoresLocalBoundBeforeTask() async throws {
        let members = """
        func f(_ d: String) {
                let device = d
                Task { print(device) }
            }
        """
        #expect(try await flagged(members) == 0)
    }

    @Test("Shorthand if-let around the Task is the unwrapped value")
    func ignoresIfLetShorthandShadow() async throws {
        #expect(try await flagged("func f() { if let device { Task { print(device) } } }") == 0)
    }

    @Test("guard-let before the Task is the unwrapped value")
    func ignoresGuardLetShadow() async throws {
        let members = """
        func f() {
                guard let device = device else { return }
                Task { print(device) }
            }
        """
        #expect(try await flagged(members) == 0)
    }

    @Test("A parameter named like a property is the parameter")
    func ignoresParameterNamedLikeProperty() async throws {
        #expect(try await flagged("func f(coherence: Double) { Task { print(coherence) } }") == 0)
    }

    @Test("A parameter's internal name is the one that binds")
    func ignoresParameterInternalName() async throws {
        #expect(try await flagged("func f(with coherence: Double) { Task { print(coherence) } }") == 0)
    }

    @Test("A static member of another type is that type's")
    func ignoresStaticMemberOnOtherType() async throws {
        #expect(try await flagged(#"func f() { Task { AppLog.device.info("x") } }"#) == 0)
    }

    @Test("An instance member of another value is that value's")
    func ignoresInstanceMemberOnOtherValue() async throws {
        #expect(try await flagged("func f(peer: Peer) { Task { print(peer.device) } }") == 0)
    }

    @Test("A local declared inside the Task is the local")
    func ignoresLocalDeclaredInsideTask() async throws {
        let members = """
        func f() {
                Task {
                    let count = 3
                    print(count)
                }
            }
        """
        #expect(try await flagged(members) == 0)
    }

    @Test("A nested closure's parameter is the parameter")
    func ignoresNestedClosureParameter() async throws {
        let members = "func f(_ names: [String]) { Task { names.forEach { device in print(device) } } }"
        #expect(try await flagged(members) == 0)
    }

    @Test("A for-in binding around the Task is the element")
    func ignoresForInBinding() async throws {
        let members = "func f(_ names: [String]) { for device in names { Task { print(device) } } }"
        #expect(try await flagged(members) == 0)
    }

    @Test("An enclosing closure's parameter is the parameter")
    func ignoresEnclosingClosureParameter() async throws {
        let members = "func f(_ items: [String]) { items.forEach { device in Task { print(device) } } }"
        #expect(try await flagged(members) == 0)
    }

    @Test("A case-let binding around the Task is the bound value")
    func ignoresCaseLetBinding() async throws {
        let members = "func f(_ maybe: String?) { if case let .some(device) = maybe { Task { print(device) } } }"
        #expect(try await flagged(members) == 0)
    }

    @Test("A switch-case binding around the Task is the bound value")
    func ignoresSwitchCaseBinding() async throws {
        let members = """
        func f(_ maybe: String?) {
                switch maybe {
                case .some(let device): Task { print(device) }
                case .none: break
                }
            }
        """
        #expect(try await flagged(members) == 0)
    }

    @Test("A for-in binding inside the Task is the element")
    func ignoresForInBindingInsideTask() async throws {
        let members = "func f(_ names: [String]) { Task { for device in names { print(device) } } }"
        #expect(try await flagged(members) == 0)
    }

    // MARK: - Must flag: the name is the property

    @Test("self?.property is flagged by its receiver, not by its name")
    func flagsWeakSelfOptionalChainedProperty() async throws {
        #expect(try await flagged("func f() { Task { [weak self] in self?.count = 1 } }") == 1)
    }

    @Test("A read before a later local of the same name is the property")
    func flagsReadBeforeLaterShadow() async throws {
        let members = """
        func f() {
                Task {
                    print(device ?? "")
                    let device = "later"
                    print(device)
                }
            }
        """
        #expect(try await flagged(members) == 1)
    }

    @Test("A local in a sibling block does not shadow")
    func flagsWhenShadowIsInSiblingScope() async throws {
        let members = """
        func f(_ flag: Bool) {
                if flag {
                    let coherence = 1.0
                    print(coherence)
                }
                Task { print(coherence) }
            }
        """
        #expect(try await flagged(members) == 1)
    }

    @Test("A local declared after the Task does not shadow")
    func flagsWhenLocalIsDeclaredAfterTheTask() async throws {
        let members = """
        func f() {
                Task { print(count) }
                let count = 3
                print(count)
            }
        """
        #expect(try await flagged(members) == 1)
    }

    @Test("A property used as the base of another member is the state touched")
    func flagsPropertyUsedAsBaseOfOtherMember() async throws {
        #expect(try await flagged("func f() { Task { print(device?.count ?? 0) } }") == 1)
    }

    @Test("self.member is the member, whatever local shares its name")
    func flagsSelfMemberDespiteShadow() async throws {
        let members = """
        func f() {
                let device = "x"
                Task { self.device = device }
            }
        """
        #expect(try await flagged(members) == 1)
    }

    @Test("After guard-let-self a bare property name is implicit self again")
    func flagsImplicitSelfAfterGuardLetSelf() async throws {
        let members = """
        func f() {
                Task { [weak self] in
                    guard let self else { return }
                    count += 1
                }
            }
        """
        #expect(try await flagged(members) == 1)
    }

    @Test("Shorthand if-let inside the Task reads the property")
    func flagsShorthandIfLetInsideTask() async throws {
        // `if let device` has no initializer, but it reads `device` — here, the
        // property, deferred. What it binds afterwards is the local.
        #expect(try await flagged("func f() { Task { if let device { print(device) } } }") == 1)
    }

    @Test("In `let x = x` inside the Task the right-hand side is the property")
    func flagsSameNameSnapshotInsideTask() async throws {
        let members = """
        func f() {
                Task {
                    let count = count
                    print(count)
                }
            }
        """
        #expect(try await flagged(members) == 1)
    }

    @Test("A nested closure capturing the property by name reads it inside the Task")
    func flagsNestedClosureCaptureOfProperty() async throws {
        let members = "func f(_ names: [String]) { Task { names.forEach { [count] _ in print(count) } } }"
        #expect(try await flagged(members) == 1)
    }

    @Test("A binding in the if-body does not reach the else")
    func flagsPropertyInElseOfIfLet() async throws {
        let members = """
        func f(_ maybe: String?) {
                Task {
                    if let device = maybe { print(device) } else { print(device ?? "") }
                }
            }
        """
        #expect(try await flagged(members) == 1)
    }

    @Test("A synchronous method through self? is flagged")
    func flagsWeakSelfOptionalChainedMethod() async throws {
        #expect(try await flagged("func f() { Task { [weak self] in self?.bump() } }") == 1)
    }

    @Test("A force-unwrapped self is self")
    func flagsForceUnwrappedSelfProperty() async throws {
        #expect(try await flagged("func f() { Task { [weak self] in self!.count = 1 } }") == 1)
    }

    @Test("A parenthesised self is self")
    func flagsParenthesisedSelf() async throws {
        #expect(try await flagged("func f() { Task { (self).count = 1 } }") == 1)
    }
}
