import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: @preconcurrency first-party import")
struct PreconcurrencyImportTests {
    private let ruleId = "concurrency.preconcurrency-first-party-import"
    private let firstParty: Set<String> = ["MyAppCore", "MyAppUI"]

    // MARK: - Must flag

    @Test("Flags @preconcurrency import of first-party module")
    func flagsFirstPartyCore() async throws {
        let code = """
        @preconcurrency import MyAppCore
        """
        let result = try await TestHelpers.audit(code, firstPartyModules: firstParty)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags @preconcurrency import of another first-party module")
    func flagsFirstPartyUI() async throws {
        let code = """
        @preconcurrency import MyAppUI
        """
        let result = try await TestHelpers.audit(code, firstPartyModules: firstParty)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must not flag

    @Test("Does not flag @preconcurrency import of third-party module")
    func ignoresThirdParty() async throws {
        let code = """
        @preconcurrency import Alamofire
        """
        let result = try await TestHelpers.audit(code, firstPartyModules: firstParty)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag first-party import on the allowlist")
    func ignoresAllowlisted() async throws {
        let code = """
        @preconcurrency import MyAppCore
        """
        let result = try await TestHelpers.audit(
            code,
            firstPartyModules: firstParty,
            allowPreconcurrencyImports: ["MyAppCore"]
        )
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag plain import without @preconcurrency")
    func ignoresPlainImport() async throws {
        let code = """
        import MyAppCore
        """
        let result = try await TestHelpers.audit(code, firstPartyModules: firstParty)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not run rule when no first-party modules supplied (single-file mode)")
    func skipsRuleWithoutFirstPartySet() async throws {
        let code = """
        @preconcurrency import MyAppCore
        """
        let result = try await TestHelpers.audit(code) // empty firstPartyModules
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }
}
