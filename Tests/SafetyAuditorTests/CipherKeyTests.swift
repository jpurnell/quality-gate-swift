import Foundation
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor

/// A key, an IV, a round count and a key size are arguments too.
///
/// `CipherArgumentTests` covers the algorithm and the mode. These cover the rest of what a cipher
/// call is given: a key written into the source (`hardcoded-key`, CWE-321), an IV or nonce that is
/// the same on every call (`static-iv`, CWE-329 / 1204 / 323), a password stretched too little or
/// not at all (`weak-kdf`, CWE-916), and a key too short to matter (`weak-key-size`, CWE-326).
///
/// See `quality-gate-swift-project/plans/proposals/ACipherIsItsArguments.md` §3.3–§3.6, §5.
@Suite("Cipher keys: hardcoded-key, static-iv, weak-kdf, weak-key-size")
struct CipherKeyTests {

    private static let keyRules: Set<String> = [
        "security.hardcoded-key", "security.static-iv", "security.weak-kdf", "security.weak-key-size",
        "security.hardcoded-secret", "security.broken-cipher", "security.ecb-mode",
        "security.homemade-digest", "security.weak-crypto",
    ]

    private func audit(
        _ code: String,
        policy: WeakCryptoPolicy = .forbidden,
        enabledRules: [String] = []
    ) async throws -> CheckResult {
        var configuration = Configuration()
        configuration.security.weakCryptoPolicy = policy
        configuration.security.enabledRules = enabledRules
        return try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: configuration)
    }

    private func findings(_ result: CheckResult, _ rule: String) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == rule }
    }

    /// Every finding from any crypto or secret rule.
    private func cryptoFindings(_ result: CheckResult) -> [Diagnostic] {
        result.diagnostics.filter { Self.keyRules.contains($0.ruleId ?? "") }
    }

    // MARK: - hardcoded-key (CWE-321)

    @Test("SymmetricKey from a string literal is one error, citing CWE-321")
    func symmetricKeyFromStringLiteral() async throws {
        let result = try await audit(#"let key = SymmetricKey(data: Data("0123456789abcdef".utf8))"#)
        let found = findings(result, "security.hardcoded-key")
        #expect(found.count == 1)
        let finding = try #require(found.first)
        #expect(finding.severity == .error)
        #expect(finding.lineNumber == 1)
        #expect(finding.message.contains("[CWE-321]"))
        #expect(cryptoFindings(result).count == 1)
    }

    /// Quorum's demonstration share: `repeating:` is the literal shape whatever the element is.
    @Test("Literal-derived key shapes are each one finding", arguments: [
        "let key = SymmetricKey(data: Data(repeating: UInt8(i &+ 1), count: 32))",
        "let key = SymmetricKey(data: [0x01, 0x02, 0x03, 0x04])",
        #"let key = SymmetricKey(data: Data(base64Encoded: "AAECAwQFBgcICQoLDA0ODw==")!)"#,
        #"let key = SymmetricKey(data: "0123456789abcdef".data(using: .utf8)!)"#,
        "let key = SymmetricKey(data: [UInt8](repeating: 7, count: 32))",
        "let key = try SymmetricKey(data: Data(count: 32))",
    ])
    func literalShapes(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.hardcoded-key").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("A key bound by a let in the same file is the literal, reported at the use")
    func keyThroughLocalLet() async throws {
        let result = try await audit("""
            func seal(_ plaintext: Data) throws -> AES.GCM.SealedBox {
                let keyBytes = Data("0123456789abcdef".utf8)
                let key = SymmetricKey(data: keyBytes)
                return try AES.GCM.seal(plaintext, using: key)
            }
            """)
        let found = findings(result, "security.hardcoded-key")
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 3)
    }

    @Test("A key bound by a static let and reached through its type is the literal")
    func keyThroughStaticLet() async throws {
        let result = try await audit("""
            enum Keys {
                static let master = Data("0123456789abcdef".utf8)
            }
            let key = SymmetricKey(data: Keys.master)
            """)
        let found = findings(result, "security.hardcoded-key")
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }

    /// Test 18: SwiftITL copies its `static let key` into an allocated buffer and passes the
    /// buffer. Following bytes through `copyBytes(to:)` is dataflow, and v1 does not do it.
    @Test("A key that reaches CCCrypt through a buffer is not seen in v1")
    func keyThroughBufferIsMissed() async throws {
        let result = try await audit("""
            struct ITLFile {
                private static let key = Data("BHUILuilfghuila3".utf8)
                func decode(_ input: Data) -> Data {
                    var keyBytes = [UInt8](repeating: 0, count: 16)
                    Self.key.copyBytes(to: &keyBytes, count: 16)
                    let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                         CCOptions(kCCOptionPKCS7Padding), keyBytes, 16, iv,
                                         i, il, o, ol, &m)
                    return output
                }
            }
            """)
        #expect(findings(result, "security.hardcoded-key").isEmpty)
    }

    @Test("Keys from a parameter, the Keychain, the environment or a generator are clean", arguments: [
        "func make(stored: Data) -> SymmetricKey { SymmetricKey(data: stored) }",
        "let key = SymmetricKey(size: .bits256)",
        #"let key = SymmetricKey(data: try keychain.read(account: "master"))"#,
        #"let key = SymmetricKey(data: Data(ProcessInfo.processInfo.environment["APP_KEY"]!.utf8))"#,
        "let key = P256.Signing.PrivateKey()",
        "let key = try P256.Signing.PrivateKey(rawRepresentation: stored)",
    ])
    func nonLiteralKeysAreClean(code: String) async throws {
        let result = try await audit(code)
        #expect(cryptoFindings(result).isEmpty)
    }

    /// A parameter of the same name shadows a file-scope constant: the key is the argument.
    @Test("A parameter that shadows a literal constant is not the constant")
    func shadowingParameterIsClean() async throws {
        let result = try await audit("""
            let key = Data("0123456789abcdef".utf8)
            func make(key: Data) -> SymmetricKey { SymmetricKey(data: key) }
            """)
        #expect(findings(result, "security.hardcoded-key").isEmpty)
    }

    @Test("A var is not a constant: it may be filled by a generator before use")
    func varIsClean() async throws {
        let result = try await audit("""
            func make() -> SymmetricKey {
                var bytes = [UInt8](repeating: 0, count: 32)
                _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                return SymmetricKey(data: bytes)
            }
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("The key argument of CCCrypt, CCCryptorCreate and CCHmac, literal, is reported", arguments: [
        #"let s = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), "0123456789abcdef", 16, iv, i, il, o, ol, &m)"#,
        #"let s = CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), "0123456789abcdef", 16, iv, &ref)"#,
        #"CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), "signing-secret", 14, message, length, &mac)"#,
    ])
    func commonCryptoKeyArgument(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.hardcoded-key").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    /// The decrypt exclusion is `static-iv`'s, not this rule's: a key in the source is readable
    /// by anyone with the binary whichever way the call goes.
    @Test("A literal key on a decrypt call is still a hard-coded key")
    func literalKeyOnDecryptIsReported() async throws {
        let result = try await audit(#"""
            let s = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), "0123456789abcdef", 16, iv, i, il, o, ol, &m)
            """#)
        #expect(findings(result, "security.hardcoded-key").count == 1)
    }

    @Test("A private key constructed from literal bytes is reported", arguments: [
        "let k = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))",
        "let k = try Curve25519.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: 9, count: 32))",
        #"let k = try P384.KeyAgreement.PrivateKey(pemRepresentation: "MIGkAgEBBDBkey")"#,
        #"let k = try _RSA.Signing.PrivateKey(derRepresentation: Data(base64Encoded: "MIIEow==")!)"#,
    ])
    func privateKeyFromLiteral(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.hardcoded-key").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    /// Assembled so that no single literal in *this* file is a PEM key.
    private static let pemHeader = "-----BEGIN EC " + "PRIVATE KEY-----"
    private static let pemFooter = "-----END EC " + "PRIVATE KEY-----"
    private static let pemBody = "MHcCAQEEIBkg4LVWM9nuwNSk3yByxZpYRTBnVJk5oooTo7ag0Yp9oAoGCCqGSM49"

    @Test("A PEM private key in a string literal is one error")
    func pemLiteralIsReported() async throws {
        let code = "let pem = \"\"\"\n\(Self.pemHeader)\n\(Self.pemBody)\n\(Self.pemFooter)\n\"\"\""
        let result = try await audit(code)
        let found = findings(result, "security.hardcoded-key")
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("A PEM key written on one line with escaped newlines is reported")
    func pemSingleLineIsReported() async throws {
        let code = "let pem = \"\(Self.pemHeader)\\n\(Self.pemBody)\\n\(Self.pemFooter)\""
        let result = try await audit(code)
        #expect(findings(result, "security.hardcoded-key").count == 1)
    }

    /// The `"http://"` case again: a parser that recognises PEM headers holds the header as a
    /// pattern, with no body. That is not a key.
    @Test("A header with no body, or a body interpolated from elsewhere, is a pattern", arguments: [
        "let marker = \"\(pemHeader)\"",
        "let found = text.contains(\"\(pemHeader)\")",
        "let pem = \"\(pemHeader)\\n\\(body)\\n\(pemFooter)\"",
    ])
    func pemHeaderOnlyIsClean(code: String) async throws {
        let result = try await audit(code)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("CryptoSwift: a literal key: argument to a cipher or MAC is reported", arguments: [
        #"let mac = try HMAC(key: "signing-secret", variant: .sha2(.sha256)).authenticate(bytes)"#,
        #"let cipher = try AES(key: Array("0123456789abcdef".utf8), blockMode: GCM(iv: iv), padding: .noPadding)"#,
    ])
    func cryptoSwiftKeyLabel(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.hardcoded-key").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("A key: label on something that is not a cipher is not a key")
    func keyLabelElsewhereIsClean() async throws {
        let result = try await audit(#"cache.set(key: "session", value: data)"#)
        #expect(cryptoFindings(result).isEmpty)
    }

    // MARK: - One literal, one finding (hardcoded-secret is CWE-798, the parent of 321)

    @Test("A secret-named PEM literal is hardcoded-key only")
    func pemNamedSecretIsOneFinding() async throws {
        let code = "let privateKey = \"\"\"\n\(Self.pemHeader)\n\(Self.pemBody)\n\(Self.pemFooter)\n\"\"\""
        let result = try await audit(code)
        #expect(findings(result, "security.hardcoded-key").count == 1)
        #expect(findings(result, "security.hardcoded-secret").isEmpty)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("A secret-named literal used as a key is hardcoded-key only")
    func secretUsedAsKeyIsOneFinding() async throws {
        let result = try await audit("""
            let apiSecret = "0123456789abcdef"
            let key = SymmetricKey(data: Data(apiSecret.utf8))
            """)
        let found = findings(result, "security.hardcoded-key")
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
        #expect(findings(result, "security.hardcoded-secret").isEmpty)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("A secret-named literal that is not used as a key stays hardcoded-secret")
    func secretNotUsedAsKeyIsHardcodedSecret() async throws {
        let result = try await audit(#"let password = "hunter2""#)
        #expect(findings(result, "security.hardcoded-secret").count == 1)
        #expect(findings(result, "security.hardcoded-key").isEmpty)
    }

    /// The yield is to a rule that is running. With `hardcoded-key` switched off, the literal
    /// still gets the finding the older rule always gave it.
    @Test("With hardcoded-key disabled, hardcoded-secret reports the literal")
    func secretReportedWhenKeyRuleDisabled() async throws {
        let result = try await audit("""
            let apiSecret = "0123456789abcdef"
            let key = SymmetricKey(data: Data(apiSecret.utf8))
            """, enabledRules: ["security.hardcoded-secret"])
        #expect(findings(result, "security.hardcoded-secret").count == 1)
        #expect(findings(result, "security.hardcoded-key").isEmpty)
    }

    // MARK: - static-iv (CWE-329, 1204, 323)

    @Test("CCCrypt encrypting with a nil IV is one error, citing CWE-329")
    func nilIVIsReported() async throws {
        let result = try await audit("""
            let s = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k, n, nil, i, il, o, ol, &m)
            """)
        let found = findings(result, "security.static-iv")
        #expect(found.count == 1)
        let finding = try #require(found.first)
        #expect(finding.severity == .error)
        #expect(finding.message.contains("[CWE-329]"))
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("A literal IV, inline or through a let, is reported", arguments: [
        "let s = CCCrypt(op, alg, CCOptions(kCCOptionPKCS7Padding), k, n, [UInt8](repeating: 0, count: 16), i, il, o, ol, &m)",
        """
        func encrypt() {
            let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
            let s = CCCrypt(op, alg, CCOptions(kCCOptionPKCS7Padding), k, n, iv, i, il, o, ol, &m)
        }
        """,
        "let s = CCCryptorCreate(CCOperation(kCCEncrypt), alg, 0, k, n, nil, &ref)",
    ])
    func literalIVIsReported(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.static-iv").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("A literal kCCDecrypt reads somebody else's IV and is clean")
    func decryptIsClean() async throws {
        let result = try await audit("""
            let s = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k, n, nil, i, il, o, ol, &m)
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    /// Test 11: ECB has no IV, so a nil one is not a second defect.
    @Test("ECB with a nil IV is ecb-mode only")
    func ecbWithNilIVIsOneFinding() async throws {
        let result = try await audit("""
            let s = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), k, n, nil, i, il, o, ol, &m)
            """)
        #expect(findings(result, "security.ecb-mode").count == 1)
        #expect(findings(result, "security.static-iv").isEmpty)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("A random IV filled by SecRandomCopyBytes is clean")
    func randomIVIsClean() async throws {
        let result = try await audit("""
            func encrypt() {
                var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
                _ = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
                let s = CCCrypt(CCOperation(kCCEncrypt), alg, CCOptions(kCCOptionPKCS7Padding), k, n, iv, i, il, o, ol, &m)
            }
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("A literal AEAD nonce is one error, citing CWE-323", arguments: [
        "let box = try AES.GCM.seal(p, using: k, nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 12)))",
        "let nonce = try ChaChaPoly.Nonce(data: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])",
    ])
    func literalNonceIsReported(code: String) async throws {
        let result = try await audit(code)
        let found = findings(result, "security.static-iv")
        #expect(found.count == 1)
        #expect(found.first?.message.contains("[CWE-323]") == true)
        #expect(cryptoFindings(result).count == 1)
    }

    /// Test 13: random once is still once.
    @Test("A nonce held in a static let and passed to seal is reported at the seal")
    func staticNonceIsReported() async throws {
        let result = try await audit("""
            struct Box {
                static let nonce = AES.GCM.Nonce()
                func seal(_ p: Data, key: SymmetricKey) throws -> AES.GCM.SealedBox {
                    try AES.GCM.seal(p, using: key, nonce: Self.nonce)
                }
            }
            """)
        let found = findings(result, "security.static-iv")
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
        #expect(found.first?.message.contains("[CWE-323]") == true)
    }

    @Test("A nonce held in a file-scope let and passed to seal is reported")
    func fileScopeNonceIsReported() async throws {
        let result = try await audit("""
            let fixedNonce = ChaChaPoly.Nonce()
            func seal(_ p: Data, key: SymmetricKey) throws -> ChaChaPoly.SealedBox {
                try ChaChaPoly.seal(p, using: key, nonce: fixedNonce)
            }
            """)
        #expect(findings(result, "security.static-iv").count == 1)
    }

    @Test("A static literal nonce is one finding, at its construction, not two")
    func staticLiteralNonceIsOneFinding() async throws {
        let result = try await audit("""
            struct Box {
                static let nonce = try! AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
                func seal(_ p: Data, key: SymmetricKey) throws -> AES.GCM.SealedBox {
                    try AES.GCM.seal(p, using: key, nonce: Self.nonce)
                }
            }
            """)
        let found = findings(result, "security.static-iv")
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }

    @Test("Nonces that are drawn per call, or read from data, are clean", arguments: [
        "let box = try AES.GCM.seal(p, using: k)",
        "let box = try AES.GCM.seal(p, using: k, nonce: AES.GCM.Nonce())",
        "let nonce = try AES.GCM.Nonce(data: header.prefix(12))",
        """
        func seal(_ p: Data, key: SymmetricKey) throws -> AES.GCM.SealedBox {
            let nonce = AES.GCM.Nonce()
            return try AES.GCM.seal(p, using: key, nonce: nonce)
        }
        """,
    ])
    func freshNonceIsClean(code: String) async throws {
        let result = try await audit(code)
        #expect(cryptoFindings(result).isEmpty)
    }

    /// The decrypt side of an AEAD: a sealed box rebuilt from a known-answer vector.
    @Test("A literal nonce rebuilding a SealedBox to open is clean")
    func sealedBoxNonceIsClean() async throws {
        let result = try await audit("""
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 12)), ciphertext: c, tag: t)
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("AES._CBC encrypting with a literal IV is CWE-329; decrypt and a random IV are clean")
    func cbcIV() async throws {
        let literal = try await audit("""
            let c = try AES._CBC.encrypt(p, using: k, iv: AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16)))
            """)
        let found = findings(literal, "security.static-iv")
        #expect(found.count == 1)
        #expect(found.first?.message.contains("[CWE-329]") == true)

        let throughLet = try await audit("""
            func encrypt() throws -> Data {
                let iv = try AES._CBC.IV(ivBytes: Array("0123456789abcdef".utf8))
                return try AES._CBC.encrypt(p, using: k, iv: iv)
            }
            """)
        #expect(findings(throughLet, "security.static-iv").count == 1)

        let decrypt = try await audit("""
            let p = try AES._CBC.decrypt(c, using: k, iv: AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16)))
            """)
        #expect(cryptoFindings(decrypt).isEmpty)

        let random = try await audit("let c = try AES._CBC.encrypt(p, using: k, iv: AES._CBC.IV())")
        #expect(cryptoFindings(random).isEmpty)
    }

    @Test("CryptoSwift: a literal iv: is CWE-329 for CBC and CWE-1204 otherwise", arguments: [
        (#"let mode = CBC(iv: Array("abcdefghijklmnop".utf8))"#, "[CWE-329]"),
        (#"let cipher = try ChaCha20(key: key, iv: Array("12345678abcd".utf8))"#, "[CWE-1204]"),
    ])
    func cryptoSwiftIV(code: String, cwe: String) async throws {
        let result = try await audit(code)
        let found = findings(result, "security.static-iv")
        #expect(found.count == 1)
        #expect(found.first?.message.contains(cwe) == true)
        #expect(cryptoFindings(result).count == 1)
    }

    // MARK: - weakCryptoPolicy governs hardcoded-key and static-iv

    @Test("Under justified, a reasoned Justification records an override for a dictated key")
    func justifiedKey() async throws {
        let result = try await audit("""
            // Justification: the published file format fixes this key and every reader must use it
            let key = SymmetricKey(data: Data("BHUILuilfghuila3".utf8))
            """, policy: .justified)
        #expect(cryptoFindings(result).isEmpty)
        #expect(result.overrides.filter { $0.ruleId == "security.hardcoded-key" }.count == 1)
    }

    @Test("Under justified, a bare marker does not clear a static IV")
    func bareJustificationOnIV() async throws {
        let result = try await audit("""
            // Justification: format
            let s = CCCrypt(CCOperation(kCCEncrypt), alg, CCOptions(kCCOptionPKCS7Padding), k, n, nil, i, il, o, ol, &m)
            """, policy: .justified)
        #expect(findings(result, "security.static-iv").count == 1)
        #expect(result.overrides.isEmpty)
    }

    // MARK: - weak-kdf (CWE-916)

    @Test("CCKeyDerivationPBKDF with a literal round count below 210,000 is one error, CWE-916", arguments: [
        "1000", "UInt32(1000)", "209_999",
    ])
    func lowRoundsAreReported(rounds: String) async throws {
        let result = try await audit("""
            let s = CCKeyDerivationPBKDF(alg, pw, n, salt, m, prf, \(rounds), out, len)
            """)
        let found = findings(result, "security.weak-kdf")
        #expect(found.count == 1)
        let finding = try #require(found.first)
        #expect(finding.severity == .error)
        #expect(finding.message.contains("[CWE-916]"))
        #expect(finding.message.contains("210,000"))
    }

    @Test("Enough rounds, or rounds not written as a literal, are clean", arguments: [
        "600_000", "210_000", "rounds", "configuration.rounds",
    ])
    func enoughRoundsAreClean(rounds: String) async throws {
        let result = try await audit("""
            let s = CCKeyDerivationPBKDF(alg, pw, n, salt, m, prf, \(rounds), out, len)
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("swift-crypto's unchecked PBKDF2 is a warning, and an error below the floor", arguments: [
        ("n", Diagnostic.Severity.warning),
        ("600_000", Diagnostic.Severity.warning),
        ("10_000", Diagnostic.Severity.error),
    ])
    func uncheckedRounds(rounds: String, severity: Diagnostic.Severity) async throws {
        let result = try await audit("""
            let key = try KDF.Insecure.PBKDF2.deriveKey(from: pw, salt: s, using: .sha256, outputByteCount: 32, unsafeUncheckedRounds: \(rounds))
            """)
        let found = findings(result, "security.weak-kdf")
        #expect(found.count == 1)
        #expect(found.first?.severity == severity)
    }

    @Test("The checked PBKDF2 overload is clean: it throws below the floor itself")
    func checkedRoundsAreClean() async throws {
        let result = try await audit("""
            let key = try KDF.Insecure.PBKDF2.deriveKey(from: pw, salt: s, using: .sha256, outputByteCount: 32, rounds: 600_000)
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("A bare digest of a password is one error", arguments: [
        "let h = SHA256.hash(data: Data(password.utf8))",
        "let h = SHA512.hash(data: user.passphrase.data(using: .utf8)!)",
        "let h = SHA384.hash(data: Data(newPasswd.utf8))",
        "let h = SHA256.hash(data: Data(userPIN.utf8))",
        "CC_SHA256(pin, CC_LONG(pin.utf8.count), &out)",
    ])
    func passwordDigestIsReported(code: String) async throws {
        let result = try await audit(code)
        let found = findings(result, "security.weak-kdf")
        #expect(found.count == 1)
        #expect(found.first?.severity == .error)
        #expect(cryptoFindings(result).count == 1)
    }

    /// §3.5: a random bearer token has no dictionary to attack, and hash-then-look-up is the
    /// correct storage for it. Whole words: `pinned` is not `pin`; `passwordless` is no password.
    @Test("A digest of a token, key or secret, or of a word that only contains 'pin', is clean", arguments: [
        "let h = SHA256.hash(data: Data(token.utf8))",
        "let h = SHA256.hash(data: Data(apiKey.utf8))",
        "let h = SHA512.hash(data: clientSecret)",
        "let h = SHA256.hash(data: pinnedCertificate)",
        "let h = SHA256.hash(data: Data(passwordlessLink.utf8))",
        "let h = SHA256.hash(data: spinner.frame)",
    ])
    func nonPasswordDigestIsClean(code: String) async throws {
        let result = try await audit(code)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("A password-hashing function that calls SHA256 is weak-kdf, not homemade-digest")
    func passwordDigestFunctionIsOneFinding() async throws {
        let result = try await audit("""
            func hashPassword(_ password: String) -> String {
                SHA256.hash(data: Data(password.utf8)).description
            }
            """)
        #expect(findings(result, "security.weak-kdf").count == 1)
        #expect(findings(result, "security.homemade-digest").isEmpty)
        #expect(cryptoFindings(result).count == 1)
    }

    // MARK: - weak-key-size (CWE-326)

    @Test("An RSA key request below 2048 bits is one error, CWE-326", arguments: [
        "let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024]",
        "let attributes = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 1024]",
        "let attributes: [String: Any] = [kSecAttrKeySizeInBits as String: 1024 as NSNumber]",
    ])
    func smallRSAIsReported(code: String) async throws {
        let result = try await audit(code)
        let found = findings(result, "security.weak-key-size")
        #expect(found.count == 1)
        let finding = try #require(found.first)
        #expect(finding.severity == .error)
        #expect(finding.message.contains("[CWE-326]"))
    }

    @Test("2048-bit RSA, a 256-bit EC key, and a size not written as a literal are clean", arguments: [
        "let a = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]",
        "let a = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256]",
        "let a = [kSecAttrKeyType: kSecAttrKeyTypeEC, kSecAttrKeySizeInBits: 256]",
        "let a = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]",
    ])
    func adequateKeySizeIsClean(code: String) async throws {
        let result = try await audit(code)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("swift-crypto keys below their floors are reported", arguments: [
        "let k = try _RSA.Signing.PrivateKey(keySize: .init(bitCount: 1024))",
        "let k = try _RSA.Encryption.PrivateKey(keySize: _RSA.Encryption.KeySize(bitCount: 1536))",
        "let k = SymmetricKey(size: .init(bitCount: 64))",
        "let k = SymmetricKey(size: SymmetricKeySize(bitCount: 96))",
    ])
    func smallSwiftCryptoKeyIsReported(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.weak-key-size").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("swift-crypto keys at or above their floors are clean", arguments: [
        "let k = try _RSA.Signing.PrivateKey(keySize: .init(bitCount: 2048))",
        "let k = try _RSA.Signing.PrivateKey(keySize: .bits3072)",
        "let k = SymmetricKey(size: .init(bitCount: 128))",
        "let k = SymmetricKey(size: .bits256)",
    ])
    func adequateSwiftCryptoKeyIsClean(code: String) async throws {
        let result = try await audit(code)
        #expect(cryptoFindings(result).isEmpty)
    }

    // MARK: - homemade-digest on SensitiveName

    /// The rule's own word list moved onto the shared matcher. `pin` and `key` are weak terms
    /// there and are asked for explicitly, as the old list included them.
    @Test("Secret-named parameters, weak terms included, still make a fold a finding", arguments: [
        "func hashKey(_ key: String) -> String { String(key.reversed()) }",
        "func hashPIN(_ pin: String) -> String { String(pin.reversed()) }",
        "func digest(passphrase: String) -> String { String(passphrase.reversed()) }",
        "func checksum(apiKey: String) -> String { String(apiKey.reversed()) }",
        "func mac(for credential: String) -> String { String(credential.reversed()) }",
    ])
    func homemadeDigestStillFires(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.homemade-digest").count == 1)
    }

    @Test("Parameters that only contain a secret word are still not secrets", arguments: [
        "func checksum(_ tokenizer: Tokenizer) -> String { tokenizer.name }",
        "func hash(keyboard: Keyboard) -> String { keyboard.name }",
        "func digest(spinner: Spinner) -> String { spinner.name }",
    ])
    func homemadeDigestWholeWords(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.homemade-digest").isEmpty)
    }
}
