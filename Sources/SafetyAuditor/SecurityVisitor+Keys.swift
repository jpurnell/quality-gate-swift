import Foundation
import QualityGateCore
import SwiftSyntax

/// What a cipher is keyed with, what it is started from, and how long the key is.
///
/// `SecurityVisitor+Cipher.swift` reads the algorithm and the mode. These rules read the rest of
/// what a call is given:
///
/// - `security.hardcoded-key` (CWE-321) — literal bytes passed where key material belongs.
/// - `security.static-iv` (CWE-329, 1204, 323) — an IV or nonce that is the same every time.
/// - `security.weak-kdf` (CWE-916) — a password stretched too little, or not at all.
/// - `security.weak-key-size` (CWE-326) — a key too short to matter.
///
/// None follows dataflow. "Literal-derived" is syntactic: a string, integer-array or
/// `Data(repeating:count:)` literal; any of those wrapped in `Data(…)`, `Array(…)`, `.utf8`,
/// `.data(using:)`, `Data(base64Encoded:)`, `Data(hexString:)`; or a name bound by a `let` in the
/// same file whose initialiser is one of those. A key copied into a buffer and the buffer passed
/// is not seen — the proposal's test 18 pins that miss.
///
/// Every "is this argument a key, an IV, a password" decision that rests on a *name* goes through
/// ``SensitiveName``: labels of CryptoSwift initialisers and of `seal(…, nonce:)`, and the
/// identifiers inside a digest's input.
///
/// See `quality-gate-swift-project/plans/proposals/ACipherIsItsArguments.md` §3.3–§3.6.
extension SecurityVisitor {

    // MARK: - Vocabulary

    /// CommonCrypto calls with a key argument, and where it is: `CCCrypt(op, alg, options, key,
    /// keyLength, iv, …)`, `CCCryptorCreate(op, alg, options, key, keyLength, iv, ref)`,
    /// `CCHmac(alg, key, keyLength, data, dataLength, out)`.
    static let commonCryptoKeyIndex: [String: Int] = ["CCCrypt": 3, "CCCryptorCreate": 3, "CCHmac": 1]

    /// The CommonCrypto calls whose IV is argument 5. Both are CBC unless the options say ECB.
    static let commonCryptoIVCalls: Set<String> = ["CCCrypt", "CCCryptorCreate"]

    /// swift-crypto and CryptoKit key families whose `PrivateKey` can be built from bytes.
    static let privateKeyFamilies: Set<String> = ["P256", "P384", "P521", "Curve25519", "_RSA"]

    /// The labels that build a private key from an encoding.
    static let privateKeyEncodings: Set<String> = ["rawRepresentation", "pemRepresentation", "derRepresentation"]

    /// CryptoSwift ciphers, block modes and MACs, whose initialisers take `key:` and `iv:` by label.
    static let cryptoSwiftKeyedTypes: Set<String> = [
        "AES", "ChaCha20", "Rabbit", "Blowfish", "HMAC", "CMAC", "CBCMAC", "Poly1305",
        "CBC", "PCBC", "CFB", "OFB", "CTR", "GCM", "CCM", "OCB",
    ]

    /// CryptoSwift types whose `iv:` is a CBC IV: the CBC modes, and `AES(key:iv:)`, which is CBC.
    static let cryptoSwiftCBCTypes: Set<String> = ["CBC", "PCBC", "AES"]

    /// Containers whose initialiser makes bytes from what it is given.
    static let byteContainers: Set<String> = [
        "Data", "Foundation.Data", "Array", "[UInt8]", "[Int8]", "Array<UInt8>", "ContiguousArray",
        "[UInt8].init", "Data.init",
    ]

    /// swift-crypto's PBKDF2 floor: the checked overload throws below it (`PBKDF2.swift:42`,
    /// swift-crypto 3.15.1). OWASP's figure for SHA-256 is higher and was not fetched.
    static let pbkdf2RoundFloor = 210_000

    /// The smallest RSA modulus and symmetric key this rule accepts, in bits.
    static let minimumRSABits = 2048
    static let minimumSymmetricBits = 128

    /// Key types for which `kSecAttrKeySizeInBits` below 2048 is normal.
    static let ellipticKeyTypes: Set<String> = [
        "kSecAttrKeyTypeEC", "kSecAttrKeyTypeECSECPrimeRandom", "kSecAttrKeyTypeECDSA",
    ]

    /// Digests that are not password hashes, by callee.
    static let fastDigestCalls: Set<String> = ["SHA256.hash", "SHA384.hash", "SHA512.hash"]
    static let commonCryptoDigests: Set<String> = ["CC_SHA224", "CC_SHA256", "CC_SHA384", "CC_SHA512"]

    // MARK: - Entry points

    /// Every key, IV, round-count and key-size check that starts at a call.
    func checkKeyArguments(_ node: FunctionCallExprSyntax) {
        checkHardcodedKey(node)
        checkStaticIV(node)
        checkWeakKDF(node)
        checkWeakKeySizeCall(node)
    }

    // MARK: - hardcoded-key (CWE-321)

    private func checkHardcodedKey(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.hardcoded-key") else { return }
        let components = Self.calleeComponents(node)
        guard let last = components.last else { return }

        // SymmetricKey(data:)
        if last == "SymmetricKey", let argument = node.arguments.first(where: { $0.label?.text == "data" }) {
            reportKeyIfLiteral(argument.expression, subject: "SymmetricKey(data:)")
        }

        // CCCrypt / CCCryptorCreate / CCHmac, positionally.
        if components.count == 1, let index = Self.commonCryptoKeyIndex[last], node.arguments.count > index {
            let argument = Array(node.arguments)[index]
            reportKeyIfLiteral(argument.expression, subject: "\(last)'s key argument")
        }

        // P256.Signing.PrivateKey(rawRepresentation:) and its siblings.
        if last == "PrivateKey", components.contains(where: Self.privateKeyFamilies.contains) {
            for argument in node.arguments {
                guard let label = argument.label?.text, Self.privateKeyEncodings.contains(label) else { continue }
                reportKeyIfLiteral(argument.expression, subject: "\(components.joined(separator: "."))(\(label):)")
            }
        }

        // CryptoSwift: `AES(key:…)`, `HMAC(key:…)` — the key is named by its label.
        if components.count == 1, Self.cryptoSwiftKeyedTypes.contains(last) {
            for argument in node.arguments {
                guard let label = argument.label?.text,
                      SensitiveName.classify(label).contains(.keyMaterial, includingWeak: true) else { continue }
                reportKeyIfLiteral(argument.expression, subject: "\(last)(\(label):)")
            }
        }
    }

    /// Reports `expression` as a hard-coded key if it is literal-derived, and claims the binding
    /// it came through so `hardcoded-secret` does not report the same literal again.
    private func reportKeyIfLiteral(_ expression: ExprSyntax, subject: String) {
        guard let evidence = literalDerivation(of: expression) else { return }
        if let binding = evidence.binding { claimedKeyBindings.insert(binding) }
        let location = expression.startLocation(converter: converter)
        reportUnderCryptoPolicy(Diagnostic(
            severity: .error,
            message: "\(subject) is given a key written into the source. Anyone with the binary has "
                + "it, and it cannot be rotated without a release. \(Self.citation("security.hardcoded-key"))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.hardcoded-key",
            suggestedFix: "Generate the key (SymmetricKey(size: .bits256), P256.Signing.PrivateKey()) and "
                + "keep it in the Keychain, or load it from configuration that is not compiled in."
        ))
    }

    /// A string literal holding a PEM private key — header *and* body.
    ///
    /// A literal that is only the header is a pattern a parser matches against, the
    /// `"http://"` case again, and is not reported. A body interpolated from elsewhere is not a
    /// literal key either.
    func checkPrivateKeyLiteral(_ node: StringLiteralExprSyntax) {
        guard isRuleEnabled("security.hardcoded-key"), Self.isPEMPrivateKey(node) else { return }
        let location = node.startLocation(converter: converter)
        reportUnderCryptoPolicy(Diagnostic(
            severity: .error,
            message: "A PEM private key is written into the source. Anyone with the binary or the "
                + "repository has it. \(Self.citation("security.hardcoded-key"))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.hardcoded-key",
            suggestedFix: "Generate the key at install time and keep it in the Keychain, or load it "
                + "from a file or secret store that is not committed."
        ))
    }

    /// Whether a literal's own text is a PEM private key with a body.
    static func isPEMPrivateKey(_ node: StringLiteralExprSyntax) -> Bool {
        let text = node.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
            .replacingOccurrences(of: "\\n", with: "\n")
        guard text.contains("-----BEGIN"), text.contains("PRIVATE KEY-----") else { return false }
        let body = text.split(whereSeparator: \.isNewline)
            .filter { !$0.contains("-----") }
            .joined()
            .filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }
        // A key body is hundreds of base64 characters; 32 rules out a stray word.
        return body.count >= 32
    }

    // MARK: - static-iv (CWE-329, CWE-1204, CWE-323)

    private func checkStaticIV(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.static-iv") else { return }
        let components = Self.calleeComponents(node)
        guard let last = components.last else { return }
        let arguments = Array(node.arguments)

        // CCCrypt / CCCryptorCreate: argument 5, unless decrypting or in ECB.
        if components.count == 1, Self.commonCryptoIVCalls.contains(last), arguments.count > 5 {
            let operation = Set(arguments[0].expression.tokens(viewMode: .sourceAccurate).map(\.text))
            let options = Set(arguments[2].expression.tokens(viewMode: .sourceAccurate).map(\.text))
            let isDecrypt = operation.contains("kCCDecrypt") && !operation.contains("kCCEncrypt")
            let iv = arguments[5].expression
            if !isDecrypt, !options.contains("kCCOptionECBMode"),
               iv.is(NilLiteralExprSyntax.self) || literalDerivation(of: iv) != nil {
                reportStaticIV(at: iv, cwe: "CWE-329",
                               what: iv.is(NilLiteralExprSyntax.self)
                                ? "\(last) encrypts in CBC mode with a nil IV, which CommonCrypto replaces with zeros"
                                : "\(last) encrypts in CBC mode with an IV written into the source")
            }
        }

        // AES._CBC.encrypt(…, iv: AES._CBC.IV(ivBytes: <literal>)).
        if last == "encrypt", components.dropLast().last == "_CBC" {
            for argument in arguments where Self.namesSecurityParameter(argument.label?.text) {
                if isLiteralCBCIV(argument.expression) {
                    reportStaticIV(at: argument.expression, cwe: "CWE-329",
                                   what: "AES._CBC.encrypt is given an IV built from literal bytes")
                }
            }
        }

        // AES.GCM.Nonce(data: <literal>) / ChaChaPoly.Nonce(data: <literal>), unless rebuilding a box to open.
        if Self.isNonceConstruction(node), let data = arguments.first(where: { $0.label?.text == "data" }),
           literalDerivation(of: data.expression) != nil, !Self.isInsideSealedBox(node) {
            reportStaticIV(at: node, cwe: "CWE-323",
                           what: "\(components.joined(separator: ".")) is built from literal bytes, so every "
                            + "message sealed with it under one key shares a nonce")
        }

        // seal(…, nonce: <a nonce held in a static or file-scope let>).
        if last == "seal", let family = components.dropLast().last, family == "GCM" || family == "ChaChaPoly" {
            for argument in arguments where Self.namesSecurityParameter(argument.label?.text) {
                checkHeldNonce(argument.expression)
            }
        }

        // CryptoSwift: `CBC(iv:)`, `ChaCha20(key:iv:)` — the IV is named by its label.
        if components.count == 1, Self.cryptoSwiftKeyedTypes.contains(last) {
            for argument in arguments where Self.namesSecurityParameter(argument.label?.text) {
                guard literalDerivation(of: argument.expression) != nil else { continue }
                let isCBC = Self.cryptoSwiftCBCTypes.contains(last)
                reportStaticIV(at: argument.expression, cwe: isCBC ? "CWE-329" : "CWE-1204",
                               what: "\(last)(\(argument.label?.text ?? "iv"):) is given an IV written into the source")
            }
        }
    }

    /// Whether a label names an IV or nonce, by the shared vocabulary's security-parameter class.
    private static func namesSecurityParameter(_ label: String?) -> Bool {
        guard let label else { return false }
        return SensitiveName.classify(label).contains(.securityParameter)
    }

    /// `AES._CBC.IV(ivBytes: <literal>)`, inline or through a `let`.
    private func isLiteralCBCIV(_ expression: ExprSyntax) -> Bool {
        var candidate = Self.unwrapped(expression)
        if let resolved = LetResolver.binding(for: candidate) {
            candidate = Self.unwrapped(resolved.value)
        }
        guard let call = candidate.as(FunctionCallExprSyntax.self),
              let bytes = call.arguments.first(where: { $0.label?.text == "ivBytes" }) else { return false }
        return literalDerivation(of: bytes.expression) != nil
    }

    /// A `nonce:` argument naming a nonce held in a `static let` or a file-scope `let`.
    ///
    /// Random once is still once. A held nonce built from literal bytes was reported at its
    /// construction, so it is not reported again here.
    private func checkHeldNonce(_ expression: ExprSyntax) {
        let candidate = Self.unwrapped(expression)
        guard let binding = LetResolver.binding(for: candidate), binding.isHeld,
              let construction = Self.unwrapped(binding.value).as(FunctionCallExprSyntax.self),
              Self.isNonceConstruction(construction) else { return }
        if let data = construction.arguments.first(where: { $0.label?.text == "data" }),
           literalDerivation(of: data.expression) != nil {
            return
        }
        reportStaticIV(at: expression, cwe: "CWE-323",
                       what: "seal is given '\(binding.name)', a nonce held in a static or file-scope "
                        + "constant, so every message sealed under one key shares it")
    }

    private func reportStaticIV(at node: some SyntaxProtocol, cwe: String, what: String) {
        let location = node.startLocation(converter: converter)
        reportUnderCryptoPolicy(Diagnostic(
            severity: .error,
            message: "\(what). A fixed IV makes equal plaintexts encrypt equally; a reused GCM nonce "
                + "also gives away the authentication key. [\(cwe)]",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.static-iv",
            suggestedFix: "Omit nonce: and let CryptoKit draw one per message, use AES._CBC.IV() or "
                + "SecRandomCopyBytes for an IV, and send the IV or nonce with the ciphertext."
        ))
    }

    /// `AES.GCM.Nonce(…)` or `ChaChaPoly.Nonce(…)`.
    static func isNonceConstruction(_ call: FunctionCallExprSyntax) -> Bool {
        let components = calleeComponents(call)
        guard components.last == "Nonce", let family = components.dropLast().last else { return false }
        return family == "GCM" || family == "ChaChaPoly"
    }

    /// Whether `node` is an argument to a `SealedBox(…)` initialiser — the decrypt side.
    private static func isInsideSealedBox(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        // Bounded: a nonce is at most an argument list and a `try` away from the box.
        for _ in 0..<5 {
            guard let candidate = current else { return false }
            if let call = candidate.as(FunctionCallExprSyntax.self) {
                return calleeComponents(call).last == "SealedBox"
            }
            current = candidate.parent
        }
        return false
    }

    // MARK: - weak-kdf (CWE-916)

    private func checkWeakKDF(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.weak-kdf") else { return }
        let components = Self.calleeComponents(node)
        guard let last = components.last else { return }
        let arguments = Array(node.arguments)

        // CCKeyDerivationPBKDF(alg, password, length, salt, length, prf, rounds, out, length).
        if components == ["CCKeyDerivationPBKDF"], arguments.count > 6,
           let rounds = Self.integerLiteral(arguments[6].expression), rounds < Self.pbkdf2RoundFloor {
            reportWeakKDF(at: arguments[6].expression, severity: .error,
                          message: "CCKeyDerivationPBKDF runs \(rounds) rounds, below swift-crypto's floor "
                            + "of 210,000 — a GPU tries that many passwords per second per round.")
        }

        // swift-crypto: KDF.Insecure.PBKDF2.deriveKey(…, unsafeUncheckedRounds:).
        if last == "deriveKey", let rounds = arguments.first(where: { $0.label?.text == "unsafeUncheckedRounds" }) {
            let count = Self.integerLiteral(rounds.expression)
            let below = count.map { $0 < Self.pbkdf2RoundFloor } ?? false
            reportWeakKDF(
                at: rounds.expression, severity: below ? .error : .warning,
                message: below
                    ? "PBKDF2 runs \(count ?? 0) rounds through unsafeUncheckedRounds:, below the 210,000 "
                        + "the checked overload enforces."
                    : "PBKDF2 is called through unsafeUncheckedRounds:, the only way under the 210,000-round "
                        + "floor the checked overload enforces.")
        }

        // A bare digest of a password: SHA256.hash(data: password…), CC_SHA256(password, …).
        let callee = components.suffix(2).joined(separator: ".")
        let input: ExprSyntax?
        if Self.fastDigestCalls.contains(callee) {
            input = arguments.first(where: { $0.label?.text == "data" })?.expression
        } else if components.count == 1, Self.commonCryptoDigests.contains(last) {
            input = arguments.first?.expression
        } else {
            input = nil
        }
        if let input, let password = Self.passwordIdentifier(in: input) {
            reportWeakKDF(at: node, severity: .error,
                          message: "\(callee) is applied to '\(password)'. A fast digest of a password is "
                            + "a dictionary attack's best case: one hash per guess, no salt, no work factor.")
        }
    }

    /// The first identifier in `expression` that names a password, PIN included.
    ///
    /// A token, key or secret is deliberately not one: a random bearer token has no dictionary to
    /// attack, and hash-then-look-up is the correct way to store it (§3.5).
    private static func passwordIdentifier(in expression: ExprSyntax) -> String? {
        for token in expression.tokens(viewMode: .sourceAccurate) {
            guard case .identifier(let text) = token.tokenKind else { continue }
            if SensitiveName.classify(text).contains(.password, includingWeak: true) { return text }
        }
        return nil
    }

    private func reportWeakKDF(at node: some SyntaxProtocol, severity: Diagnostic.Severity, message: String) {
        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: severity,
            message: message + " \(Self.citation("security.weak-kdf"))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.weak-kdf",
            suggestedFix: "Derive with PBKDF2 at 600,000 rounds or more (OWASP's figure for SHA-256), "
                + "or scrypt / Argon2, with a random salt per password."
        ))
    }

    // MARK: - weak-key-size (CWE-326)

    /// `_RSA.*.PrivateKey(keySize: .init(bitCount: N))` and `SymmetricKey(size: .init(bitCount: N))`.
    private func checkWeakKeySizeCall(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.weak-key-size") else { return }
        let components = Self.calleeComponents(node)
        let (label, minimum): (String, Int)
        if components.last == "PrivateKey", components.first == "_RSA" {
            (label, minimum) = ("keySize", Self.minimumRSABits)
        } else if components.last == "SymmetricKey" {
            (label, minimum) = ("size", Self.minimumSymmetricBits)
        } else {
            return
        }
        guard let size = node.arguments.first(where: { $0.label?.text == label }),
              let construction = Self.unwrapped(size.expression).as(FunctionCallExprSyntax.self),
              let bitCount = construction.arguments.first(where: { $0.label?.text == "bitCount" }),
              let bits = Self.integerLiteral(bitCount.expression), bits < minimum else { return }
        reportWeakKeySize(at: size.expression, bits: bits, minimum: minimum,
                          subject: components.joined(separator: "."))
    }

    /// `kSecAttrKeySizeInBits: N` in a dictionary literal, N below 2048, unless the same literal
    /// asks for an elliptic-curve key.
    func checkKeySizeAttribute(_ node: DeclReferenceExprSyntax) {
        guard isRuleEnabled("security.weak-key-size"), node.baseName.text == "kSecAttrKeySizeInBits" else { return }
        var current = node.parent
        var element: DictionaryElementSyntax?
        // Bounded: the constant is at most an `as String` cast away from the element.
        for _ in 0..<4 {
            guard let candidate = current else { return }
            if let found = candidate.as(DictionaryElementSyntax.self) { element = found; break }
            current = candidate.parent
        }
        guard let element, element.key.position <= node.position, node.endPosition <= element.key.endPosition,
              let bits = Self.integerLiteral(element.value), bits < Self.minimumRSABits,
              let list = element.parent else { return }
        let names = Set(list.tokens(viewMode: .sourceAccurate).map(\.text))
        guard names.isDisjoint(with: Self.ellipticKeyTypes) else { return }
        reportWeakKeySize(at: node, bits: bits, minimum: Self.minimumRSABits, subject: "kSecAttrKeySizeInBits")
    }

    private func reportWeakKeySize(at node: some SyntaxProtocol, bits: Int, minimum: Int, subject: String) {
        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: .error,
            message: "\(subject) asks for a \(bits)-bit key; \(minimum) is the least that is not "
                + "breakable with public effort. \(Self.citation("security.weak-key-size"))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.weak-key-size",
            suggestedFix: minimum == Self.minimumRSABits
                ? "Use 2048 bits or more for RSA (3072 for use past 2030), or a P-256 key."
                : "Use SymmetricKey(size: .bits256)."
        ))
    }

    // MARK: - Literal-derived

    /// Where a literal-derived value came from: inline, or through the `let` named here.
    struct LiteralEvidence {
        /// The pattern of the `let` the value was reached through, if any.
        let binding: SyntaxIdentifier?
    }

    /// Whether `expression` is literal-derived (see the type's documentation), and through which
    /// binding. Follows one `let`, never a chain: the proposal's definition, and its one-file limit.
    func literalDerivation(of expression: ExprSyntax, followingBindings: Bool = true) -> LiteralEvidence? {
        let expression = Self.unwrapped(expression)
        if Self.isLiteralBytes(expression) { return LiteralEvidence(binding: nil) }
        if let member = expression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "utf8",
           let base = member.base {
            return literalDerivation(of: base, followingBindings: followingBindings)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return literalDerivation(ofCall: call, followingBindings: followingBindings)
        }
        guard followingBindings, let binding = LetResolver.binding(for: expression),
              literalDerivation(of: binding.value, followingBindings: false) != nil else { return nil }
        return LiteralEvidence(binding: binding.pattern)
    }

    private func literalDerivation(ofCall call: FunctionCallExprSyntax, followingBindings: Bool) -> LiteralEvidence? {
        let callee = call.calledExpression.trimmedDescription
        let arguments = Array(call.arguments)
        let labels = arguments.map { $0.label?.text }
        if Self.byteContainers.contains(callee) {
            // `Data(repeating: x, count: n)` is the literal shape whatever `x` is (test 17), and
            // `Data(count: n)` is n zeros.
            if labels.contains("repeating") && labels.contains("count") { return LiteralEvidence(binding: nil) }
            if labels == ["count"], callee.contains("Data") { return LiteralEvidence(binding: nil) }
            guard let first = arguments.first,
                  [nil, "base64Encoded", "hexString", "bytes"].contains(first.label?.text) else { return nil }
            return literalDerivation(of: first.expression, followingBindings: followingBindings)
        }
        // `"…".data(using: .utf8)`
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "data", labels == ["using"], let base = member.base {
            return literalDerivation(of: base, followingBindings: followingBindings)
        }
        return nil
    }

    /// A string literal with no interpolation, or a non-empty array of integer literals.
    private static func isLiteralBytes(_ expression: ExprSyntax) -> Bool {
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return !literal.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
        }
        if let array = expression.as(ArrayExprSyntax.self) {
            return !array.elements.isEmpty && array.elements.allSatisfy { $0.expression.is(IntegerLiteralExprSyntax.self) }
        }
        return false
    }

    // MARK: - Syntax helpers

    /// `expression` without `try`, `!`, `?` or parentheses around it.
    static func unwrapped(_ expression: ExprSyntax) -> ExprSyntax {
        var current = expression
        // Bounded: each pass removes one wrapper, and real code nests a handful at most.
        for _ in 0..<8 {
            if let tryExpr = current.as(TryExprSyntax.self) {
                current = tryExpr.expression
            } else if let force = current.as(ForceUnwrapExprSyntax.self) {
                current = force.expression
            } else if let optional = current.as(OptionalChainingExprSyntax.self) {
                current = optional.expression
            } else if let tuple = current.as(TupleExprSyntax.self), tuple.elements.count == 1,
                      let only = tuple.elements.first, only.label == nil {
                current = only.expression
            } else {
                break
            }
        }
        return current
    }

    /// The callee's dotted name, without a leading module or implicit-member dot:
    /// `CryptoKit.AES.GCM.Nonce` → `["AES", "GCM", "Nonce"]`, `.init` → `["init"]`.
    static func calleeComponents(_ call: FunctionCallExprSyntax) -> [String] {
        var components = call.calledExpression.trimmedDescription
            .split(separator: ".").map(String.init)
        if let first = components.first, first == "CryptoKit" || first == "Crypto" || first == "_CryptoExtras" {
            components.removeFirst()
        }
        return components
    }

    /// The value of an integer literal, looking through `UInt32(…)`, `NSNumber(value:)`, `as`
    /// casts and parentheses. `nil` for anything that is not written as a number.
    static func integerLiteral(_ expression: ExprSyntax) -> Int? {
        let expression = unwrapped(expression)
        if let literal = expression.as(IntegerLiteralExprSyntax.self) {
            let text = literal.literal.text.replacingOccurrences(of: "_", with: "")
            if text.hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
            if text.hasPrefix("0o") { return Int(text.dropFirst(2), radix: 8) }
            if text.hasPrefix("0b") { return Int(text.dropFirst(2), radix: 2) }
            return Int(text)
        }
        if let sequence = expression.as(SequenceExprSyntax.self), sequence.elements.count == 3,
           let first = sequence.elements.first,
           sequence.elements.dropFirst().first?.is(UnresolvedAsExprSyntax.self) == true {
            return integerLiteral(first)
        }
        if let call = expression.as(FunctionCallExprSyntax.self), call.arguments.count == 1,
           let only = call.arguments.first, only.label == nil || only.label?.text == "value",
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           callee.baseName.text.first?.isUppercase == true {
            return integerLiteral(only.expression)
        }
        return nil
    }
}
