import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: @unchecked Sendable")
struct UncheckedSendableTests {
    private let ruleId = "concurrency.unchecked-sendable-no-justification"

    @Test("ConcurrencyAuditor identity")
    func identity() {
        let auditor = ConcurrencyAuditor()
        #expect(auditor.id == "concurrency")
        #expect(auditor.name == "Concurrency Auditor")
    }

    // MARK: - Must flag

    @Test("Flags final class with @unchecked Sendable and no justification")
    func flagsClassNoJustification() async throws {
        let code = """
        final class Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags struct with @unchecked Sendable and no justification")
    func flagsStructNoJustification() async throws {
        let code = """
        struct Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags retroactive @unchecked Sendable extension")
    func flagsExtensionNoJustification() async throws {
        let code = """
        struct Foo {}
        extension Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags @unchecked Sendable with mutable state and no justification")
    func flagsWithMutableState() async throws {
        let code = """
        final class Foo: @unchecked Sendable {
            var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags when justification comment is two lines above (adjacency required)")
    func flagsJustificationTwoLinesAbove() async throws {
        let code = """
        // Justification: lock-protected

        final class Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags when justification appears below the declaration")
    func flagsJustificationBelow() async throws {
        let code = """
        final class Foo: @unchecked Sendable {}
        // Justification: lock-protected
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags when justification is in a block comment")
    func flagsBlockCommentJustification() async throws {
        let code = """
        /* Justification: lock-protected */
        final class Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must not flag

    @Test("Does not flag when justification is on the line directly above")
    func ignoresJustificationLineAbove() async throws {
        let code = """
        // Justification: synchronized via NSLock
        final class Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag when justification is trailing on the same line")
    func ignoresJustificationSameLineTrailing() async throws {
        let code = """
        final class Foo: @unchecked Sendable {} // Justification: lock-protected
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag with custom justification keyword")
    func ignoresCustomKeyword() async throws {
        let code = """
        // SAFETY: protected by actor
        final class Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code, justificationKeyword: "SAFETY:")
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
