import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: Sendable class with mutable state")
struct SendableClassMutableStateTests {
    private let ruleId = "concurrency.sendable-class-mutable-state"

    // MARK: - Must flag

    @Test("Flags Sendable class with public var")
    func flagsPublicVar() async throws {
        let code = """
        final class Foo: Sendable {
            var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags Sendable class with private var")
    func flagsPrivateVar() async throws {
        let code = """
        final class Foo: Sendable {
            private var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags Sendable class with private(set) var")
    func flagsPrivateSetVar() async throws {
        let code = """
        final class Foo: Sendable {
            private(set) var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags Sendable class with uninitialized stored var")
    func flagsUninitializedVar() async throws {
        let code = """
        final class Foo: Sendable {
            var x: Int = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Emits one diagnostic per offending property in a Sendable class")
    func emitsOnePerProperty() async throws {
        let code = """
        final class Foo: Sendable {
            var x = 0
            var y = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        let count = result.diagnostics.filter { $0.ruleId == ruleId }.count
        #expect(count == 2)
    }

    // MARK: - Must not flag

    @Test("Does not flag Sendable class with only let properties")
    func ignoresLetOnly() async throws {
        let code = """
        final class Foo: Sendable {
            let x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag class without Sendable conformance")
    func ignoresNonSendableClass() async throws {
        let code = """
        final class Foo {
            var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag struct with Sendable conformance and var")
    func ignoresSendableStruct() async throws {
        let code = """
        struct Foo: Sendable {
            var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag @unchecked Sendable class (handled by other rule)")
    func ignoresUncheckedSendable() async throws {
        let code = """
        // Justification: lock-protected
        final class Foo: @unchecked Sendable {
            var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
