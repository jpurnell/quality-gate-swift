import Foundation
import Testing
@testable import UnreachableCodeAuditor
@testable import QualityGateCore

/// Tests that the v5 well-known-witness allow-list keeps stdlib protocol
/// witnesses alive even when the index doesn't record references to them
/// (which is the case for `Hashable`/`Codable`/`SwiftUI.View.body` etc).
@Suite("Well-known witness allow-list", .serialized)
struct WellKnownWitnessTests {

    private static let fixtureRoot: URL = {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CrossModuleFixture", isDirectory: true)
    }()

    private func auditFixture() async throws -> CheckResult {
        try await UnreachableCodeAuditor().audit(at: Self.fixtureRoot, configuration: Configuration())
    }

    private func flagged(_ result: CheckResult, name: String) -> Bool {
        let id = "unreachable.cross_module.unreachable_from_entry"
        return result.diagnostics.contains { d in
            d.ruleId == id && (d.message.contains("'\(name)'") == true)
        }
    }

    @Test("Does not flag manually-implemented hash(into:)")
    func keepsHashInto() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "hash(into:)"))
    }

    @Test("Does not flag custom == operator")
    func keepsEqualityOperator() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "=="))
    }

    @Test("Does not flag manually-implemented encode(to:)")
    func keepsEncodeTo() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "encode(to:)"))
    }
}
