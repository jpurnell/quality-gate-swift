import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: Sendable class with non-Sendable property")
struct SendableClassNonSendablePropertyTests {
    private let ruleId = "concurrency.sendable-class-non-sendable-property"

    // MARK: - Must flag

    @Test("Flags non-@Sendable closure property in Sendable class")
    func flagsClosureNotSendable() async throws {
        let code = """
        final class Foo: Sendable {
            let handler: (Int) -> Void = { _ in }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags generic non-@Sendable closure property")
    func flagsGenericClosure() async throws {
        let code = """
        final class Foo<T>: Sendable {
            let handler: (T) -> Void = { _ in }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must not flag

    @Test("Does not flag @Sendable closure property")
    func ignoresSendableClosure() async throws {
        let code = """
        final class Foo: Sendable {
            let handler: @Sendable (Int) -> Void = { _ in }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag stdlib Sendable property type")
    func ignoresStringProperty() async throws {
        let code = """
        final class Foo: Sendable {
            let name: String = ""
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag closure property when class is not Sendable")
    func ignoresWhenNotSendable() async throws {
        let code = """
        final class Foo {
            let handler: (Int) -> Void = { _ in }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
