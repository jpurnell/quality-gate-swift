import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: Justification Quality")
struct JustificationQualityTests {

    @Test("Rejects too-short justification")
    func rejectsTooShort() async throws {
        let code = """
        // Justification: uses a lock for access
        final class Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "justification.too-short" })
        #expect(!result.diagnostics.contains { $0.ruleId == "concurrency.unchecked-sendable-no-justification" })
    }

    @Test("Rejects generic 'works fine' justification")
    func rejectsGeneric() async throws {
        let code = """
        // Justification: works fine
        final class Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "justification.generic" })
        #expect(!result.diagnostics.contains { $0.ruleId == "concurrency.unchecked-sendable-no-justification" })
    }

    @Test("Accepts substantive justification")
    func acceptsSubstantive() async throws {
        let code = """
        // Justification: synchronized via NSLock in all public methods, mutation only in init
        final class Foo: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "justification.too-short" })
        #expect(!result.diagnostics.contains { $0.ruleId == "justification.generic" })
        #expect(!result.diagnostics.contains { $0.ruleId == "concurrency.unchecked-sendable-no-justification" })
    }

    @Test("Flags duplicate justifications as warning")
    func flagsDuplicates() async throws {
        let code = """
        // Justification: synchronized via NSLock in all public methods ensuring thread safety
        final class Foo: @unchecked Sendable {}
        // Justification: synchronized via NSLock in all public methods ensuring thread safety
        final class Bar: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "justification.duplicate" })
        #expect(result.diagnostics.first { $0.ruleId == "justification.duplicate" }?.severity == .warning)
    }

    @Test("Accepts different justifications on multiple classes")
    func acceptsDifferentJustifications() async throws {
        let code = """
        // Justification: synchronized via NSLock in all public methods ensuring thread safety
        final class Foo: @unchecked Sendable {}
        // Justification: protected by actor isolation with exclusive access via DispatchQueue barrier
        final class Bar: @unchecked Sendable {}
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == "justification.duplicate" })
    }

    @Test("Rejects single-word justification on nonisolated(unsafe)")
    func rejectsSingleWordOnNonisolatedUnsafe() async throws {
        let code = """
        // Justification: debug counter only
        nonisolated(unsafe) static var counter = 0
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == "justification.too-short" })
        #expect(!result.diagnostics.contains { $0.ruleId == "concurrency.nonisolated-unsafe-no-justification" })
    }
}
