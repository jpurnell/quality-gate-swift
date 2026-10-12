import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// Trust has more than three off switches.
///
/// `security.tls-disabled` matched three identifiers — `disableEvaluation`,
/// `allowsExpiredCertificates`, `allowsExpiredRoots` — none of which is URLSession,
/// Network.framework, SwiftNIO or AsyncHTTPClient API. The one way certificate validation was
/// actually switched off in the portfolio, NIOSSL's `certificateVerification = .none`, it had
/// never heard of. These tests pin the widened rule and the three rules beside it.
///
/// See `quality-gate-swift-project/plans/proposals/TrustHasMoreThanThreeOffSwitches.md` §5;
/// the numbers in the test names are that section's.
@Suite("Trust rules")
struct TrustRulesTests {

    private func audit(_ code: String) async throws -> CheckResult {
        try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: Configuration())
    }

    private func findings(_ rule: String, in code: String) async throws -> [Diagnostic] {
        try await audit(code).diagnostics.filter { $0.ruleId == rule }
    }

    // MARK: - tls-disabled, widened (CWE-295)

    @Test("1. certificateVerification = .none is an error")
    func noneAssignment() async throws {
        let found = try await findings("security.tls-disabled", in: """
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == 2)
        #expect(found.first?.message.contains("[CWE-295]") == true)
    }

    @Test("2. The SwiftMCPClient shape — behind a flag — is still an error")
    func conditionalNone() async throws {
        let found = try await findings("security.tls-disabled", in: """
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            if trustSelfSignedCertificates {
                tlsConfig.certificateVerification = .none
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 3)
    }

    @Test("3. .fullVerification is clean")
    func fullVerification() async throws {
        let result = try await audit("tlsConfig.certificateVerification = .fullVerification")
        #expect(!result.diagnostics.contains { ($0.ruleId ?? "").hasPrefix("security.") })
    }

    @Test("4. .none with options is an error")
    func noneWithOptions() async throws {
        let found = try await findings("security.tls-disabled", in: """
            config.certificateVerification = .none(.init(validatePresentedCertificates: false))
            """)
        #expect(found.count == 1)
    }

    @Test("5. AsyncHTTPClient's initialiser label is matched")
    func asyncHTTPClientLabel() async throws {
        let found = try await findings("security.tls-disabled", in: """
            let configuration = HTTPClient.Configuration(certificateVerification: .none)
            """)
        #expect(found.count == 1)
    }

    @Test("6. NIOSSL's older factory label is matched")
    func forClientLabel() async throws {
        let found = try await findings("security.tls-disabled", in: """
            let tls = TLSConfiguration.forClient(certificateVerification: .none)
            """)
        #expect(found.count == 1)
    }

    /// On a server, `certificateVerification` is about *client* certificates: `.none` means no
    /// client certificate is asked for, which is NIOSSL's own default for a server and right for
    /// every server that is not doing mutual TLS. VaultMCP and SwiftMCPServer both build one.
    @Test("A server configuration's .none is clean")
    func serverNone() async throws {
        let result = try await audit("""
            var config = TLSConfiguration.makeServerConfiguration(certificateChain: chain, privateKey: key)
            config.certificateVerification = .none
            let other = TLSConfiguration.forServer(certificateChain: chain, privateKey: key, certificateVerification: .none)
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.tls-disabled" })
    }

    @Test("7. .optionalVerification is a server setting and is clean")
    func optionalVerification() async throws {
        let result = try await audit("serverConfig.certificateVerification = .optionalVerification")
        #expect(!result.diagnostics.contains { ($0.ruleId ?? "").hasPrefix("security.") })
    }

    @Test("8. Optional's .none is not a certificate setting")
    func optionalNone() async throws {
        let result = try await audit("""
            let x: Foo? = .none
            value = .none
            call(mode: .none)
            """)
        #expect(!result.diagnostics.contains { ($0.ruleId ?? "").hasPrefix("security.") })
    }

    @Test(".none chosen by a ternary in the assignment is an error")
    func ternaryNone() async throws {
        let found = try await findings("security.tls-disabled", in: """
            config.certificateVerification = insecure ? .none : .fullVerification
            """)
        #expect(found.count == 1)
    }

    @Test("A local typed CertificateVerification initialised to .none is an error")
    func typedLocalNone() async throws {
        let found = try await findings("security.tls-disabled", in: """
            let mode: CertificateVerification = .none
            """)
        #expect(found.count == 1)
    }

    @Test("9. SecTrustSetExceptions is an error")
    func setExceptions() async throws {
        let found = try await findings("security.tls-disabled", in: """
            SecTrustSetExceptions(trust, SecTrustCopyExceptions(trust))
            """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("10. Alamofire's DisabledTrustEvaluator is an error")
    func disabledEvaluator() async throws {
        let found = try await findings("security.tls-disabled", in: """
            let manager = ServerTrustManager(evaluators: ["h": DisabledTrustEvaluator()])
            """)
        #expect(found.count == 1)
    }

    @Test("11. allowsExpiredCertificates = true is unchanged")
    func expiredUnchanged() async throws {
        let found = try await findings("security.tls-disabled", in: "trust.allowsExpiredCertificates = true")
        #expect(found.count == 1)
    }

    // MARK: - tls-no-hostname (CWE-297)

    @Test("12. .noHostnameVerification is an error citing CWE-297")
    func noHostname() async throws {
        let result = try await audit("tlsConfig.certificateVerification = .noHostnameVerification")
        let found = result.diagnostics.filter { $0.ruleId == "security.tls-no-hostname" }
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.message.contains("[CWE-297]") == true)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.tls-disabled" })
    }

    @Test(".noHostnameVerification as an initialiser label is an error")
    func noHostnameLabel() async throws {
        let found = try await findings("security.tls-no-hostname", in: """
            let configuration = HTTPClient.Configuration(certificateVerification: .noHostnameVerification)
            """)
        #expect(found.count == 1)
    }

    /// A server checking a client certificate has no hostname to check it against; NIOSSL's own
    /// `makeServerConfigurationWithMTLS` sets this value for that reason.
    @Test("A server configuration's .noHostnameVerification is clean")
    func serverNoHostname() async throws {
        let result = try await audit("""
            var config = TLSConfiguration.makeServerConfiguration(certificateChain: chain, privateKey: key)
            config.certificateVerification = .noHostnameVerification
            let other = TLSConfiguration.forServer(certificateChain: chain, privateKey: key, certificateVerification: .noHostnameVerification)
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.tls-no-hostname" })
    }

    @Test("13. An Alamofire evaluator told not to validate the host is an error")
    func validateHostFalse() async throws {
        let found = try await findings("security.tls-no-hostname", in: """
            let a = PinnedCertificatesTrustEvaluator(validateHost: false)
            let b = PublicKeysTrustEvaluator(performDefaultValidation: false, validateHost: false)
            """)
        #expect(found.count == 2)
    }

    /// Alamofire's own documentation: `validateHost` validates the host "even if
    /// `performDefaultValidation` is `false`". Turning default validation off alone leaves the
    /// host checked — the proposal listed it as a hostname finding, and Alamofire's source says
    /// otherwise. Measured against Alamofire's test suite, it was 27 false findings.
    @Test("performDefaultValidation: false alone still validates the host, and is clean")
    func performDefaultValidationAlone() async throws {
        let result = try await audit("""
            let a = PinnedCertificatesTrustEvaluator(performDefaultValidation: false)
            let b = RevocationTrustEvaluator(performDefaultValidation: false, validateHost: true)
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.tls-no-hostname" })
    }

    @Test("An Alamofire evaluator left to validate the host is clean")
    func validateHostTrue() async throws {
        let result = try await audit("""
            let a = PinnedCertificatesTrustEvaluator(validateHost: true)
            let b = DefaultTrustEvaluator()
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.tls-no-hostname" })
    }

    @Test("14. SecPolicyCreateSSL(true, nil) is an error")
    func sslPolicyNoHost() async throws {
        let found = try await findings("security.tls-no-hostname", in: "let policy = SecPolicyCreateSSL(true, nil)")
        #expect(found.count == 1)
    }

    @Test("15. SecPolicyCreateSSL with a hostname is clean, and so is a client policy")
    func sslPolicyWithHost() async throws {
        let result = try await audit("""
            let policy = SecPolicyCreateSSL(true, host as CFString)
            let client = SecPolicyCreateSSL(false, nil)
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.tls-no-hostname" })
    }

    @Test("A basic X.509 policy set on a trust object is an error")
    func basicX509OnTrust() async throws {
        let found = try await findings("security.tls-no-hostname", in: """
            SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            let policy = SecPolicyCreateBasicX509()
            SecTrustSetPolicies(trust, policy)
            """)
        #expect(found.count == 2)
    }

    @Test("A basic X.509 policy not set on a trust object is clean")
    func basicX509Elsewhere() async throws {
        let result = try await audit("let policy = SecPolicyCreateBasicX509()")
        #expect(!result.diagnostics.contains { $0.ruleId == "security.tls-no-hostname" })
    }

    // MARK: - trust-handler-accepts-all (CWE-295)

    private static let handlerSignature = """
        func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        """

    @Test("16. A delegate that answers with the trust it never evaluated is an error")
    func acceptsAll() async throws {
        let found = try await findings("security.trust-handler-accepts-all", in: """
            \(Self.handlerSignature)
                completionHandler(.useCredential, URLCredential(trust: c.protectionSpace.serverTrust!))
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(found.first?.lineNumber == 3)
        #expect(found.first?.message.contains("[CWE-295]") == true)
    }

    @Test("17. Evaluated first, with the result deciding, is clean")
    func evaluatedFirst() async throws {
        let result = try await audit("""
            \(Self.handlerSignature)
                guard let trust = c.protectionSpace.serverTrust else { return }
                var error: CFError?
                guard SecTrustEvaluateWithError(trust, &error) else {
                    completionHandler(.cancelAuthenticationChallenge, nil); return
                }
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.trust-handler-accepts-all" })
    }

    @Test("18. Evaluated and ignored is an error")
    func evaluatedAndIgnored() async throws {
        let found = try await findings("security.trust-handler-accepts-all", in: """
            \(Self.handlerSignature)
                guard let trust = c.protectionSpace.serverTrust else { return }
                _ = SecTrustEvaluateWithError(trust, nil)
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
            """)
        #expect(found.count == 1)
    }

    @Test("A bare evaluation statement whose Bool is dropped is an error")
    func bareEvaluation() async throws {
        let found = try await findings("security.trust-handler-accepts-all", in: """
            \(Self.handlerSignature)
                guard let trust = c.protectionSpace.serverTrust else { return }
                SecTrustEvaluateWithError(trust, nil)
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
            """)
        #expect(found.count == 1)
    }

    @Test("19. Default handling is clean")
    func defaultHandling() async throws {
        let result = try await audit("""
            \(Self.handlerSignature)
                completionHandler(.performDefaultHandling, nil)
            }
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.trust-handler-accepts-all" })
    }

    @Test("20. The async form returning the credential unevaluated is an error")
    func asyncForm() async throws {
        let found = try await findings("security.trust-handler-accepts-all", in: """
            func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge) async
                -> (URLSession.AuthChallengeDisposition, URLCredential?) {
                guard let trust = c.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
                return (.useCredential, URLCredential(trust: trust))
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }

    @Test("The task-level and web-view handlers are handlers too")
    func otherHandlers() async throws {
        let found = try await findings("security.trust-handler-accepts-all", in: """
            func urlSession(_ s: URLSession, task: URLSessionTask, didReceive c: URLAuthenticationChallenge,
                            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
                completionHandler(.useCredential, URLCredential(trust: c.protectionSpace.serverTrust!))
            }
            func webView(_ w: WKWebView, didReceive c: URLAuthenticationChallenge,
                         completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
                completionHandler(.useCredential, URLCredential(trust: c.protectionSpace.serverTrust!))
            }
            """)
        #expect(found.count == 2)
    }

    @Test("An evaluator whose throwing evaluate decides is clean")
    func throwingEvaluator() async throws {
        let result = try await audit("""
            \(Self.handlerSignature)
                guard let trust = c.protectionSpace.serverTrust else { return }
                do {
                    try evaluator.evaluate(trust, forHost: c.protectionSpace.host)
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } catch {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.trust-handler-accepts-all" })
    }

    @Test("21. A password credential is not a trust decision")
    func passwordCredential() async throws {
        let result = try await audit("""
            \(Self.handlerSignature)
                completionHandler(.useCredential, URLCredential(user: u, password: p, persistence: .none))
            }
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.trust-handler-accepts-all" })
    }

    @Test("22. A verify block that always completes true is an error")
    func verifyBlockAcceptsAll() async throws {
        let found = try await findings("security.trust-handler-accepts-all", in: """
            sec_protocol_options_set_verify_block(opts, { _, _, complete in complete(true) }, queue)
            """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
    }

    @Test("A verify block written as a trailing closure with shorthand arguments is an error")
    func verifyBlockShorthand() async throws {
        let found = try await findings("security.trust-handler-accepts-all", in: """
            sec_protocol_options_set_verify_block(opts, queue) {
                $2(true)
            }
            """)
        #expect(found.count == 1)
    }

    @Test("23. A verify block that completes with the evaluation is clean")
    func verifyBlockEvaluates() async throws {
        let result = try await audit("""
            sec_protocol_options_set_verify_block(opts, { _, trust, complete in
                complete(SecTrustEvaluateWithError(sec_trust_copy_ref(trust).takeRetainedValue(), nil))
            }, queue)
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.trust-handler-accepts-all" })
    }

    @Test("24. The same expression outside a handler is clean")
    func notAHandler() async throws {
        let result = try await audit("""
            func answer(_ trust: SecTrust) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
                return (.useCredential, URLCredential(trust: trust))
            }
            """)
        #expect(!result.diagnostics.contains { $0.ruleId == "security.trust-handler-accepts-all" })
    }

    // MARK: - trust-anchors-widened (CWE-295, warning)

    @Test("25. Re-enabling the built-in anchors is a warning")
    func anchorsWidened() async throws {
        let found = try await findings("security.trust-anchors-widened", in: """
            SecTrustSetAnchorCertificatesOnly(trust, false)
            """)
        #expect(found.count == 1)
        #expect(found.first?.severity == .warning)
        #expect(found.first?.message.contains("[CWE-295]") == true)
    }

    @Test("26. Restricting to the supplied anchors is clean")
    func anchorsOnly() async throws {
        let result = try await audit("SecTrustSetAnchorCertificatesOnly(trust, true)")
        #expect(!result.diagnostics.contains { $0.ruleId == "security.trust-anchors-widened" })
    }

    // MARK: - Acknowledgement, through the one `report(_:)` every security rule shares

    static let fixtures: [(rule: String, code: String)] = [
        ("security.tls-disabled", "tlsConfig.certificateVerification = .none"),
        ("security.tls-no-hostname", "tlsConfig.certificateVerification = .noHostnameVerification"),
        ("security.trust-anchors-widened", "SecTrustSetAnchorCertificatesOnly(trust, false)"),
        ("security.trust-handler-accepts-all",
         "sec_protocol_options_set_verify_block(opts, { _, _, complete in complete(true) }, queue)"),
    ]

    static let ruleIds = fixtures.map(\.rule)

    private func fixture(_ rule: String) throws -> String {
        try #require(Self.fixtures.first { $0.rule == rule }).code
    }

    @Test("35. A reasoned // SECURITY: acknowledgement is recorded, not reported", arguments: ruleIds)
    func acknowledged(rule: String) async throws {
        let code = """
            // SECURITY: loopback only; the peer is a child process this tool spawned itself
            \(try fixture(rule))
            """
        let result = try await audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == rule })
        let override = try #require(result.overrides.first { $0.ruleId == rule })
        #expect(override.lineNumber == 2)
        #expect(override.justification.hasPrefix("loopback only"))
    }

    @Test("36. A bare // SECURITY: leaves the finding standing", arguments: ruleIds)
    func bareMarker(rule: String) async throws {
        let result = try await audit("// SECURITY:\n" + (try fixture(rule)))
        #expect(result.diagnostics.filter { $0.ruleId == rule }.count == 1)
        #expect(!result.overrides.contains { $0.ruleId == rule })
    }

    @Test("A short // SECURITY: reason is rejected with a sentence saying why", arguments: ruleIds)
    func shortMarker(rule: String) async throws {
        let result = try await audit("// SECURITY: dev only\n" + (try fixture(rule)))
        let finding = try #require(result.diagnostics.first { $0.ruleId == rule })
        #expect(finding.message.contains("not accepted"))
        #expect(finding.message.contains("2 words"))
    }

    @Test("Each rule can be switched off by enabledRules", arguments: ruleIds)
    func disabledByConfiguration(rule: String) async throws {
        var configuration = Configuration()
        configuration.security.enabledRules = ["security.ssrf"]
        let result = try await SafetyAuditor().auditSource(
            try fixture(rule), fileName: "test.swift", configuration: configuration)
        #expect(!result.diagnostics.contains { $0.ruleId == rule })
    }

    // MARK: - Manifest

    @Test("Each new rule is in the manifest with its CWE, severity and OWASP columns", arguments: [
        ("security.tls-no-hostname", ["CWE-297"], "ERROR", "A07:2021"),
        ("security.trust-handler-accepts-all", ["CWE-295"], "ERROR", "A07:2021"),
        ("security.trust-anchors-widened", ["CWE-295"], "WARNING", "A07:2021"),
    ])
    func manifestRow(ruleId: String, cwes: [String], severity: String, top10: String) throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == ruleId })
        #expect(rule.cwes == cwes)
        #expect(rule.severity == severity)
        #expect(rule.owaspMobile == "M5 Insecure Communication")
        #expect(rule.owaspTop10?.hasPrefix(top10) == true)
    }

    @Test("tls-disabled's description names the stacks it now knows")
    func tlsDescription() throws {
        let rule = try #require(SecurityRuleManifest.rules.first { $0.ruleId == "security.tls-disabled" })
        for stack in ["URLSession", "Security", "NIOSSL", "AsyncHTTPClient", "Alamofire"] {
            #expect(rule.description.contains(stack))
        }
        #expect(!rule.description.contains("("), "the staleness workflow reads up to the first ')'")
    }
}
