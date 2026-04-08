import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: nonisolated(unsafe)")
struct NonisolatedUnsafeTests {
    private let ruleId = "concurrency.nonisolated-unsafe-no-justification"

    // MARK: - Must flag

    @Test("Flags top-level nonisolated(unsafe) static var")
    func flagsTopLevelStatic() async throws {
        let code = """
        nonisolated(unsafe) static var counter = 0
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags nonisolated(unsafe) var inside actor")
    func flagsInsideActor() async throws {
        let code = """
        actor A {
            nonisolated(unsafe) var x = 0
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must not flag

    @Test("Does not flag plain nonisolated (no unsafe)")
    func ignoresPlainNonisolated() async throws {
        let code = """
        actor A {
            nonisolated var x: Int { 0 }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag nonisolated(unsafe) with justification directly above")
    func ignoresJustified() async throws {
        let code = """
        // Justification: process-wide debug counter, race acceptable
        nonisolated(unsafe) static var counter = 0
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
