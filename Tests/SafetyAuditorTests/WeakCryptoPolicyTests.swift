import Foundation
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor

/// Holding `security.weak-crypto` at a chosen strength.
///
/// ## Why this policy exists
///
/// The rule is right almost always: MD5 and SHA-1 are broken, and new work must not rely on
/// them. But "almost always" is not "always", and the exception is not exotic — **reading a
/// file format somebody else wrote**. ECMA-376 encrypted spreadsheets from the Excel 2010 era
/// derive their key with SHA-1, and the hash is named *in the file*. A reader either computes
/// it or refuses to open the document. No amount of care at the call site changes that, and
/// the auditor's standing advice — "use SHA-256 or stronger" — is not available.
///
/// Before this, such a project had three options, and a project that forbids suppression had
/// none: silence the rule, exclude the checker, or drop the feature. The fourth option is the
/// one `@unchecked Sendable` already uses here — **say why, in the source, where a reviewer
/// reads it**. That is what `justified` asks for.
///
/// The default stays `forbidden`, so nothing changes for anyone who has not opted in.
@Suite("Weak crypto policy")
struct WeakCryptoPolicyTests {

    private let sha1Call = """
    import Crypto
    func digest(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }
    """

    private func audit(_ code: String, policy: WeakCryptoPolicy?) async throws -> CheckResult {
        var configuration = Configuration()
        if let policy {
            configuration.security.weakCryptoPolicy = policy
        }
        let auditor = SafetyAuditor()
        return try await auditor.auditSource(code, fileName: "test.swift",
                                             configuration: configuration)
    }

    private func weakCryptoFindings(_ result: CheckResult) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == "security.weak-crypto" }
    }

    // MARK: - The default does not move

    @Test("By default a weak hash is reported, exactly as before")
    func defaultStillReports() async throws {
        let result = try await audit(sha1Call, policy: nil)
        #expect(!weakCryptoFindings(result).isEmpty)
    }

    @Test("The default policy is forbidden, so existing projects see no change")
    func defaultPolicyIsForbidden() {
        #expect(WeakCryptoPolicy.default == .forbidden)
        #expect(SecurityAuditorConfig.default.weakCryptoPolicy == .forbidden)
    }

    // MARK: - justified

    @Test("Under `justified`, an unjustified weak hash is still reported")
    func justifiedStillReportsWithoutAReason() async throws {
        let result = try await audit(sha1Call, policy: .justified)
        let findings = weakCryptoFindings(result)
        #expect(!findings.isEmpty)
        // The message has to say what is being asked for, or the setting is a riddle.
        #expect(findings.contains { $0.message.contains("Justification:") })
    }

    @Test("Under `justified`, a stated reason on the line above clears it")
    func justifiedAcceptsAStatedReason() async throws {
        let code = """
        import Crypto
        func digest(_ data: Data) -> Data {
            // Justification: the file format names SHA-1; reading it is not a security choice.
            Data(Insecure.SHA1.hash(data: data))
        }
        """
        let result = try await audit(code, policy: .justified)
        #expect(weakCryptoFindings(result).isEmpty)
    }

    @Test("A justification elsewhere in the file does not clear an unrelated call")
    func justificationMustBeAdjacent() async throws {
        let code = """
        import Crypto
        // Justification: this comment is nowhere near the call below.
        func unrelated() {}

        func digest(_ data: Data) -> Data {
            Data(Insecure.SHA1.hash(data: data))
        }
        """
        let result = try await audit(code, policy: .justified)
        #expect(!weakCryptoFindings(result).isEmpty)
    }

    // MARK: - What is deliberately not offered

    /// There is no `aggregate` level, and that is a decision rather than an omission.
    ///
    /// `TrapPolicy` has one because traps are everywhere in code nobody owns, and reporting
    /// 73 of them is how a checker gets excluded wholesale. Weak hashes are rare, and a weak
    /// hash quietly counted into a footnote is the exact outcome this rule exists to prevent.
    /// Two levels: report it, or state why it is right.
    @Test("The policy offers only forbidden and justified")
    func onlyTwoLevelsExist() {
        #expect(WeakCryptoPolicy.allCases.count == 2)
        #expect(WeakCryptoPolicy.allCases.contains(.forbidden))
        #expect(WeakCryptoPolicy.allCases.contains(.justified))
    }

    // MARK: - Configuration

    @Test("The policy decodes from the security section of the config file")
    func decodesFromConfiguration() throws {
        let json = Data("""
        {"security": {"weakCryptoPolicy": "justified"}}
        """.utf8)
        let configuration = try JSONDecoder().decode(Configuration.self, from: json)
        #expect(configuration.security.weakCryptoPolicy == .justified)
    }

    @Test("A config that says nothing about it keeps the old behaviour")
    func absentKeyKeepsForbidden() throws {
        let json = Data("""
        {"security": {"enabledRules": []}}
        """.utf8)
        let configuration = try JSONDecoder().decode(Configuration.self, from: json)
        #expect(configuration.security.weakCryptoPolicy == .forbidden)
    }
}
