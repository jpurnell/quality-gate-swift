import Foundation
import Testing
@testable import UnreachableCodeAuditor
@testable import QualityGateCore

/// Cross-module dead-code tests powered by IndexStoreDB.
///
/// The auditor's `auditPackage(at:)` is responsible for ensuring the
/// fixture's index store is fresh (auto-build) — these tests do **not**
/// pre-build, so every run exercises `IndexStoreManager.ensureFresh`.
@Suite("UnreachableCodeAuditor cross-module", .serialized)
struct CrossModuleTests {

    private static let fixtureRoot: URL = {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CrossModuleFixture", isDirectory: true)
    }()

    private static let ruleId = "unreachable.cross_module.unreachable_from_entry"

    private func auditFixture() async throws -> CheckResult {
        let auditor = UnreachableCodeAuditor()
        return try await auditor.auditPackage(at: Self.fixtureRoot, configuration: Configuration())
    }

    private func flagged(_ result: CheckResult, name: String) -> Bool {
        result.diagnostics.contains { d in
            d.ruleId == Self.ruleId && (d.message.contains(name) == true)
        }
    }

    // MARK: - Positive cases (must be flagged)

    @Test("Flags unreferenced internal function across modules")
    func flagsDeadInternal() async throws {
        let result = try await auditFixture()
        #expect(flagged(result, name: "deadInternal"))
    }

    @Test("Flags unreferenced private function in executable target")
    func flagsDeadInExe() async throws {
        let result = try await auditFixture()
        #expect(flagged(result, name: "deadInExe"))
    }

    @Test("Flags head of dead call chain")
    func flagsDeadChain() async throws {
        let result = try await auditFixture()
        // v3.1 conservative filter: only the head of a dead chain (zero
        // incoming refs) is flagged. Catching every link of `A→B→C` would
        // require a complete call graph; the v3 BFS infrastructure is in
        // place for that, but the final filter still requires zero refs to
        // avoid false positives from incomplete edges.
        #expect(flagged(result, name: "deadChainA"))
    }

    @Test("Flags unmatched enum case")
    func flagsDeadEnumCase() async throws {
        let result = try await auditFixture()
        #expect(flagged(result, name: "deadCase"))
    }

    // MARK: - Negative cases (must NOT be flagged)

    @Test("Does not flag cross-module-referenced internal function")
    func keepsLiveInternal() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "liveInternal"))
    }

    @Test("Does not flag any link of a live call chain")
    func keepsLiveChain() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "liveChainX"))
        #expect(!flagged(result, name: "liveChainY"))
        #expect(!flagged(result, name: "liveChainZ"))
    }

    @Test("Does not flag enum case matched in a switch")
    func keepsUsedEnumCase() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "usedCase"))
    }

    @Test("Does not flag public API of a library product")
    func keepsPublicLibraryAPI() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "publicLibraryAPI"))
    }

    @Test("Does not flag protocol witness method")
    func keepsProtocolWitness() async throws {
        let result = try await auditFixture()
        // `greet()` on Hello is a witness — must be kept alive.
        #expect(!result.diagnostics.contains { d in
            d.ruleId == Self.ruleId &&
            (d.message.contains("greet") == true) &&
            (d.filePath?.contains("Witness.swift") == true)
        })
    }

    @Test("Does not flag @objc method")
    func keepsObjcMethod() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "ping"))
    }

    @Test("Honors // LIVE: exemption comment")
    func honorsLiveExemption() async throws {
        let result = try await auditFixture()
        #expect(!flagged(result, name: "zombieButLive"))
    }

    // The auto-build code path is exercised by every other test in this
    // suite (none of them pre-build the fixture), so a dedicated
    // delete-and-rebuild test would be redundant — and the SwiftPM
    // incremental cache makes it brittle to assert "this run rebuilt".
}
