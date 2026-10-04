import Foundation
import Testing
@testable import QualityGateCore
@testable import SafetyAuditor

/// A cipher is its arguments.
///
/// `security.weak-crypto` reads callee names: `CC_MD5`, `Insecure.SHA1`. Every other way to get
/// a cipher wrong in Swift goes through a call whose *name* is fine — `CCCrypt`,
/// `CCCryptorCreate` — and whose *arguments* are the defect: an algorithm constant, a mode bit.
/// And one way calls nothing at all: a function that says it hashes a secret and folds bytes.
///
/// See `quality-gate-swift-project/plans/proposals/ACipherIsItsArguments.md`.
@Suite("Cipher arguments: broken-cipher, ecb-mode, homemade-digest")
struct CipherArgumentTests {

    private static let cipherRules: Set<String> = [
        "security.broken-cipher", "security.ecb-mode", "security.homemade-digest", "security.weak-crypto",
    ]

    private func audit(_ code: String, policy: WeakCryptoPolicy = .forbidden) async throws -> CheckResult {
        var configuration = Configuration()
        configuration.security.weakCryptoPolicy = policy
        return try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: configuration)
    }

    private func findings(_ result: CheckResult, _ rule: String) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == rule }
    }

    /// Every finding from the four crypto rules, whatever the rule.
    private func cryptoFindings(_ result: CheckResult) -> [Diagnostic] {
        result.diagnostics.filter { Self.cipherRules.contains($0.ruleId ?? "") }
    }

    // MARK: - broken-cipher (CWE-327)

    @Test("DES behind CCAlgorithm(…) is one error, citing CWE-327")
    func desIsReported() async throws {
        let result = try await audit("""
            let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmDES), opts, k, n, iv, i, il, o, ol, &m)
            """)
        let found = findings(result, "security.broken-cipher")
        #expect(found.count == 1)
        let finding = try #require(found.first)
        #expect(finding.severity == .error)
        #expect(finding.lineNumber == 1)
        #expect(finding.message.contains("[CWE-327]"))
        #expect(finding.message.contains("kCCAlgorithmDES"))
    }

    @Test("Every broken CommonCrypto algorithm constant is one finding", arguments: [
        "kCCAlgorithmDES", "kCCAlgorithm3DES", "kCCAlgorithmRC4", "kCCAlgorithmRC2",
        "kCCAlgorithmCAST", "kCCAlgorithmBlowfish",
    ])
    func eachBrokenConstant(constant: String) async throws {
        let result = try await audit("let algorithm = CCAlgorithm(\(constant))")
        #expect(findings(result, "security.broken-cipher").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    /// `kCCModeRC4` is how `CCCryptorCreateWithMode` asks for RC4 — the same cipher, by its mode.
    @Test("RC4 named as a mode is the same broken cipher")
    func rc4ModeIsReported() async throws {
        let result = try await audit("""
            let status = CCCryptorCreateWithMode(op, CCMode(kCCModeRC4), alg, pad, nil, k, n, nil, 0, 0, 0, &ref)
            """)
        #expect(findings(result, "security.broken-cipher").count == 1)
    }

    @Test("A qualified reference is still one finding, not two")
    func qualifiedConstantIsOneFinding() async throws {
        let result = try await audit("let algorithm = CommonCrypto.kCCAlgorithmDES")
        #expect(findings(result, "security.broken-cipher").count == 1)
    }

    @Test("AES is clean", arguments: ["kCCAlgorithmAES", "kCCAlgorithmAES128"])
    func aesIsClean(constant: String) async throws {
        let result = try await audit("let algorithm = CCAlgorithm(\(constant))")
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("CryptoSwift Blowfish and Rabbit, constructed with a key, are reported", arguments: [
        "let cipher = try Blowfish(key: key, blockMode: CBC(iv: iv), padding: .pkcs7)",
        "let cipher = try Rabbit(key: key)",
        "let cipher = try Rabbit(key: key, iv: iv)",
    ])
    func cryptoSwiftBrokenCiphers(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.broken-cipher").count == 1)
    }

    /// A game's `Rabbit(name:)` is not a stream cipher. The CryptoSwift initialisers all lead
    /// with `key:`, and that label is what the rule reads.
    @Test("A type that happens to be called Rabbit is not a cipher")
    func rabbitWithoutKeyIsClean() async throws {
        let result = try await audit(#"let pet = Rabbit(name: "Peter")"#)
        #expect(cryptoFindings(result).isEmpty)
    }

    // MARK: - ecb-mode (CWE-327)

    @Test("kCCOptionECBMode is one error, citing CWE-327")
    func ecbOptionIsReported() async throws {
        let result = try await audit("let options = CCOptions(kCCOptionECBMode)")
        let found = findings(result, "security.ecb-mode")
        #expect(found.count == 1)
        let finding = try #require(found.first)
        #expect(finding.severity == .error)
        #expect(finding.message.contains("[CWE-327]"))
    }

    @Test("ECB named as a mode for CCCryptorCreateWithMode is reported")
    func ecbModeIsReported() async throws {
        let result = try await audit("let mode = CCMode(kCCModeECB)")
        #expect(findings(result, "security.ecb-mode").count == 1)
    }

    @Test("PKCS#7 padding is not a mode and is clean")
    func paddingIsClean() async throws {
        let result = try await audit("let options = CCOptions(kCCOptionPKCS7Padding)")
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("CryptoSwift ECB, as a block mode, is reported", arguments: [
        "let cipher = try AES(key: key, blockMode: ECB(), padding: .pkcs7)",
        "let cipher = try AES(key: key, blockMode: .ECB, padding: .noPadding)",
        "let cipher = try AES(key: key, blockMode: .ecb, padding: .noPadding)",
    ])
    func cryptoSwiftECB(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.ecb-mode").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }

    /// `.ecb` is a common enough case name that, outside a `blockMode:` argument, it says nothing
    /// about a cipher.
    @Test("An enum case called .ecb elsewhere is not a cipher mode")
    func ecbCaseElsewhereIsClean() async throws {
        let result = try await audit("let region = Region.lookup(.ecb)")
        #expect(cryptoFindings(result).isEmpty)
    }

    // MARK: - Decrypt reads somebody else's choice

    /// SwiftITL reads iTunes `.itl` files, which are AES-128-ECB because Apple made them so. The
    /// mode on the decrypt side was chosen by whoever encrypted; reporting the reader asks them
    /// to fix someone else's file. The proposal's `static-iv` excludes decrypt for exactly this
    /// reason, and the same reasoning holds for a mode or an algorithm.
    @Test("ECB in a literal kCCDecrypt call is the encryptor's choice, not the reader's")
    func ecbOnDecryptIsClean() async throws {
        let result = try await audit("""
            let status = CCCrypt(CCOperation(kCCDecrypt),
                                 CCAlgorithm(kCCAlgorithmAES),
                                 CCOptions(kCCOptionECBMode),
                                 keyBytes, key.count,
                                 nil,
                                 input, capacity,
                                 output, capacity,
                                 &moved)
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("DES in a literal kCCDecrypt call is reading legacy data, not choosing DES")
    func desOnDecryptIsClean() async throws {
        let result = try await audit("""
            let status = CCCrypt(UInt32(kCCDecrypt), CCAlgorithm(kCCAlgorithmDES), 0, k, n, iv, i, il, o, ol, &m)
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("ECB on encrypt is reported")
    func ecbOnEncryptIsReported() async throws {
        let result = try await audit("""
            let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                 CCOptions(kCCOptionECBMode), k, n, nil, i, il, o, ol, &m)
            """)
        let found = findings(result, "security.ecb-mode")
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 2)
    }

    /// Only a literal `kCCDecrypt` says which way the call goes. A variable could be either.
    @Test("An operation held in a variable is not known to be decrypt")
    func variableOperationIsReported() async throws {
        let result = try await audit("""
            let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), k, n, nil, i, il, o, ol, &m)
            """)
        #expect(findings(result, "security.ecb-mode").count == 1)
    }

    /// Two defects, two fixes: replacing DES with AES leaves ECB, and the reverse leaves DES.
    /// Each constant is its own finding, at its own column.
    @Test("DES in ECB mode is two findings, one per constant")
    func desInECBIsTwoFindings() async throws {
        let result = try await audit("""
            let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode), k, n, nil, i, il, o, ol, &m)
            """)
        #expect(findings(result, "security.broken-cipher").count == 1)
        #expect(findings(result, "security.ecb-mode").count == 1)
        #expect(cryptoFindings(result).count == 2)
    }

    // MARK: - Safe shapes

    @Test("CryptoKit AEADs and SHA-256 are clean", arguments: [
        "let box = try AES.GCM.seal(plaintext, using: key)",
        "let box = try ChaChaPoly.seal(plaintext, using: key)",
        "let digest = SHA256.hash(data: data)",
        "let key = SymmetricKey(size: .bits256)",
        "let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)",
    ])
    func cryptoKitIsClean(code: String) async throws {
        let result = try await audit(code)
        #expect(cryptoFindings(result).isEmpty)
    }

    // MARK: - weakCryptoPolicy governs ciphers as well as hashes

    private static let justifiedECB = """
        // Justification: the iTunes library format is AES-128-ECB and we must write it back
        let options = CCOptions(kCCOptionECBMode)
        """

    @Test("Under justified, a reasoned Justification records an override and reports nothing")
    func justifiedRecordsOverride() async throws {
        let result = try await audit(Self.justifiedECB, policy: .justified)
        #expect(cryptoFindings(result).isEmpty)
        let override = try #require(result.overrides.first { $0.ruleId == "security.ecb-mode" })
        #expect(override.lineNumber == 2)
        #expect(override.justification == "the iTunes library format is AES-128-ECB and we must write it back")
        #expect(result.overrides.filter { $0.ruleId == "security.ecb-mode" }.count == 1)
    }

    @Test("Under forbidden, the same comment is not a switch")
    func forbiddenIgnoresJustification() async throws {
        let result = try await audit(Self.justifiedECB, policy: .forbidden)
        #expect(findings(result, "security.ecb-mode").count == 1)
        #expect(result.overrides.isEmpty)
    }

    @Test("Under justified, a bare marker is no reason", arguments: [
        "// Justification:",
        "// Justification: —",
        "// Justification: legacy",
        "// Justification: the format says so",
    ])
    func emptyJustificationIsRejected(marker: String) async throws {
        let result = try await audit("""
            \(marker)
            let algorithm = CCAlgorithm(kCCAlgorithmDES)
            """, policy: .justified)
        let finding = try #require(findings(result, "security.broken-cipher").first)
        #expect(finding.severity == .error)
        #expect(finding.message.contains("Justification"))
        #expect(result.overrides.isEmpty)
    }

    /// The weak-hash rule is held to the same bar it shares a policy with: a reason, recorded.
    @Test("Under justified, weak-crypto records its override too")
    func weakCryptoJustificationIsRecorded() async throws {
        let result = try await audit("""
            // Justification: the file format names SHA-1; reading it is not a security choice.
            let digest = Insecure.SHA1.hash(data: data)
            """, policy: .justified)
        #expect(cryptoFindings(result).isEmpty)
        #expect(result.overrides.filter { $0.ruleId == "security.weak-crypto" }.count == 1)
    }

    @Test("Under justified, weak-crypto rejects a bare marker")
    func weakCryptoBareJustificationIsRejected() async throws {
        let result = try await audit("""
            // Justification:
            let digest = Insecure.SHA1.hash(data: data)
            """, policy: .justified)
        #expect(findings(result, "security.weak-crypto").count == 1)
    }

    // MARK: - homemade-digest (CWE-1240)

    /// `SwiftMCPServer`'s `APIKeyAuthenticator.hashKey`, verbatim. Documented as SHA-256; a
    /// 32-byte XOR fold. The words "bcrypt", "Argon2" and "SHA-256" appear — in comments, which
    /// call nothing.
    private static let hashKeyVerbatim = """
        /// Hash an API key using SHA-256
        /// This prevents storing keys in plaintext in memory
        private static func hashKey(_ key: String) -> String {
            guard let data = key.data(using: .utf8) else {
                return ""
            }

            // Use SHA-256 for hashing
            // Note: For production, consider using a proper password hashing algorithm
            // like bcrypt or Argon2, but SHA-256 is sufficient for API keys
            var hash = [UInt8](repeating: 0, count: 32)
            data.withUnsafeBytes { buffer in
                // Simple SHA-256 implementation would go here
                // For now, use a basic hash (this should be replaced with proper crypto)
                let bytes = buffer.bindMemory(to: UInt8.self)
                for (index, byte) in bytes.enumerated() {
                    hash[index % 32] ^= byte
                }
            }

            return hash.map { ($0 < 16 ? "0" : "") + String($0, radix: 16, uppercase: false) }.joined()
        }
        """

    @Test("The hashKey fold is one warning, citing CWE-1240, on the declaration")
    func hashKeyIsReported() async throws {
        let result = try await audit(Self.hashKeyVerbatim)
        let found = findings(result, "security.homemade-digest")
        #expect(found.count == 1)
        let finding = try #require(found.first)
        #expect(finding.severity == .warning)
        #expect(finding.lineNumber == 3)
        #expect(finding.message.contains("[CWE-1240]"))
        #expect(finding.message.contains("hashKey"))
    }

    @Test("A digest of a secret that calls a recognised primitive is clean", arguments: [
        "func hash(of token: String) -> String { SHA256.hash(data: Data(token.utf8)).hex }",
        "func hashToken(_ token: String) -> Data { Data(SHA512.hash(data: Data(token.utf8))) }",
        """
        func hmacSecret(_ secret: Data, message: Data) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        }
        """,
        """
        func digestPassword(_ password: String, salt: [UInt8]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 32)
            _ = CCKeyDerivationPBKDF(alg, password, password.utf8.count, salt, salt.count, prf, 600_000, &out, 32)
            return out
        }
        """,
        """
        func sha256(apiKey: String) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 32)
            _ = CC_SHA256(apiKey, CC_LONG(apiKey.utf8.count), &out)
            return out
        }
        """,
    ])
    func primitiveIsClean(code: String) async throws {
        let result = try await audit(code)
        #expect(cryptoFindings(result).isEmpty)
    }

    /// Delegation: the callee is a digest-named function and is examined on its own.
    @Test("A digest that delegates to another digest function is clean")
    func delegationIsClean() async throws {
        let result = try await audit("func hashToken(_ token: String) -> String { digest(of: token) }")
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("hash(into:) is excluded by signature")
    func hashIntoIsClean() async throws {
        let result = try await audit("""
            func hash(into hasher: inout Hasher) { hasher.combine(token) }
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    @Test("A content hash with no secret parameter is not this rule's business")
    func contentHashIsClean() async throws {
        let result = try await audit("""
            func contentHash(_ file: Data) -> String {
                var acc: UInt8 = 0
                for byte in file { acc ^= byte }
                return String(acc)
            }
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    /// Whole words: `tokenizer` is not `token`, and `macAddress` is not a MAC.
    @Test("Names are matched as whole words", arguments: [
        "func checksum(_ tokenizer: Tokenizer) -> String { tokenizer.name }",
        "func macAddress(for token: String) -> String { lookup(token) }",
        "func rehash(_ key: String) -> String { String(key.reversed()) }",
    ])
    func wholeWordsOnly(code: String) async throws {
        let result = try await audit(code)
        #expect(findings(result, "security.homemade-digest").isEmpty)
    }

    @Test("A protocol requirement has no body and is not a finding")
    func requirementIsClean() async throws {
        let result = try await audit("""
            protocol Hashing { func hashPassword(_ password: String) -> String }
            """)
        #expect(cryptoFindings(result).isEmpty)
    }

    // MARK: - One site, one finding

    /// A function that hashes a password with MD5 is a weak hash, and `weak-crypto` says so at
    /// the call. It is not *also* a homemade digest: it called a primitive — the wrong one, which
    /// is the other rule's finding. Counting it twice would double the noise and halve the
    /// information.
    @Test("A digest of a secret through MD5 is weak-crypto only")
    func weakPrimitiveIsNotHomemade() async throws {
        let result = try await audit("""
            func hashPassword(_ password: String) -> String {
                Insecure.MD5.hash(data: Data(password.utf8)).description
            }
            """)
        #expect(findings(result, "security.weak-crypto").count == 1)
        #expect(findings(result, "security.homemade-digest").isEmpty)
        #expect(cryptoFindings(result).count == 1)
    }

    @Test("CC_MD5 inside a digest-named function is weak-crypto only")
    func ccMD5IsNotHomemade() async throws {
        let result = try await audit("""
            func md5Digest(secret: String) -> [UInt8] {
                var out = [UInt8](repeating: 0, count: 16)
                CC_MD5(secret, CC_LONG(secret.utf8.count), &out)
                return out
            }
            """)
        #expect(findings(result, "security.weak-crypto").count == 1)
        #expect(cryptoFindings(result).count == 1)
    }
}
