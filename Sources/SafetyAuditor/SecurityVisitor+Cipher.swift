import Foundation
import QualityGateCore
import SwiftSyntax

/// Cryptography that is wrong because of what was *passed*, not what was *called*.
///
/// `security.weak-crypto` reads callee names. `CCCrypt(kCCEncrypt, kCCAlgorithmDES,
/// kCCOptionECBMode, …)` calls a function whose name is fine; the algorithm and the mode are
/// arguments, and those are the defect. So these rules match the *constant*, wherever it
/// appears — behind `CCAlgorithm(…)`, in a variable, qualified or not — and one more rule matches
/// a function that claims a digest and calls nothing.
///
/// See `quality-gate-swift-project/plans/proposals/ACipherIsItsArguments.md`.
extension SecurityVisitor {

    // MARK: - Vocabulary

    /// `CommonCryptor.h`'s algorithm constants for ciphers that are broken or too small-blocked
    /// to use. The header marks none of them deprecated, which is why a rule has to.
    /// `kCCModeRC4` is RC4 asked for by mode, through `CCCryptorCreateWithMode`.
    static let brokenCipherConstants: Set<String> = [
        "kCCAlgorithmDES", "kCCAlgorithm3DES", "kCCAlgorithmRC4", "kCCAlgorithmRC2",
        "kCCAlgorithmCAST", "kCCAlgorithmBlowfish", "kCCModeRC4",
    ]

    /// CryptoSwift's broken ciphers, by type name. Matched only when constructed with a leading
    /// `key:` argument, which every CryptoSwift initialiser for them has and a game's
    /// `Rabbit(name:)` does not.
    static let brokenCipherTypes: Set<String> = ["Blowfish", "Rabbit"]

    /// ECB, as an option bit (`CCCrypt`) and as a mode (`CCCryptorCreateWithMode`).
    static let ecbConstants: Set<String> = ["kCCOptionECBMode", "kCCModeECB"]

    /// CommonCrypto calls whose first argument is the operation.
    static let commonCryptorCalls: Set<String> = [
        "CCCrypt", "CCCryptorCreate", "CCCryptorCreateWithMode",
        "CCCryptorCreateFromData", "CCCryptorCreateFromDataWithMode",
    ]

    // MARK: - broken-cipher / ecb-mode (CWE-327)

    /// Reports a broken algorithm or ECB, named by a constant or by a CryptoSwift construction.
    ///
    /// Called for every `DeclReferenceExprSyntax`, which is also the `declName` of a member access
    /// — so `CommonCrypto.kCCAlgorithmDES` is visited once, not twice.
    func checkCipherReference(_ node: DeclReferenceExprSyntax) {
        let name = node.baseName.text
        if Self.brokenCipherConstants.contains(name) || isCryptoSwiftBrokenCipher(node) {
            reportCipher(node, ruleId: "security.broken-cipher", subject: name,
                         message: "'\(name)' selects a broken cipher. DES and RC2 have 56-bit or "
                            + "weaker effective keys, 3DES, CAST and Blowfish have 64-bit blocks "
                            + "(Sweet32), and RC4's keystream is biased.",
                         suggestedFix: "Use AES.GCM or ChaChaPoly from CryptoKit, or "
                            + "kCCAlgorithmAES with a random IV and a MAC.")
        } else if Self.ecbConstants.contains(name) || isCryptoSwiftECB(node) {
            reportCipher(node, ruleId: "security.ecb-mode", subject: name,
                         message: "'\(name)' selects ECB mode. ECB encrypts equal blocks to equal "
                            + "ciphertext, so the structure of the plaintext shows through.",
                         suggestedFix: "Use an AEAD — AES.GCM or ChaChaPoly from CryptoKit — which "
                            + "draws its own nonce.")
        }
    }

    /// `Blowfish(key: …)`, `Rabbit(key: …)`.
    private func isCryptoSwiftBrokenCipher(_ node: DeclReferenceExprSyntax) -> Bool {
        guard Self.brokenCipherTypes.contains(node.baseName.text),
              let call = node.parent?.as(FunctionCallExprSyntax.self),
              call.calledExpression.id == node.id else { return false }
        return call.arguments.first?.label?.text == "key"
    }

    /// `ECB()` — CryptoSwift's block mode — or `.ECB` / `.ecb` passed as `blockMode:`.
    ///
    /// The implicit-member form needs the label: `.ecb` is an ordinary enum case name, and
    /// outside a `blockMode:` argument it says nothing about a cipher.
    private func isCryptoSwiftECB(_ node: DeclReferenceExprSyntax) -> Bool {
        let name = node.baseName.text
        if name == "ECB", let call = node.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == node.id, call.arguments.isEmpty {
            return true
        }
        guard name == "ECB" || name == "ecb",
              let member = node.parent?.as(MemberAccessExprSyntax.self),
              member.base == nil else { return false }
        return member.parent?.as(LabeledExprSyntax.self)?.label?.text == "blockMode"
    }

    /// Whether `node` is an argument to a CommonCrypto call whose operation is literally
    /// `kCCDecrypt`.
    ///
    /// The algorithm and mode on the decrypt side were chosen by whoever encrypted. Reporting
    /// the reader asks them to fix someone else's file — SwiftITL reads iTunes `.itl` files,
    /// which are AES-128-ECB because Apple made them so. The proposal excludes decrypt from
    /// `static-iv` for the same reason. Only a literal counts: an operation in a variable may
    /// be either.
    private func isInsideLiteralDecrypt(_ node: some SyntaxProtocol) -> Bool {
        var current = node.parent
        // Bounded: the constant is at most a cast and an argument list away from the call.
        for _ in 0..<6 {
            guard let candidate = current else { return false }
            if let call = candidate.as(FunctionCallExprSyntax.self),
               Self.commonCryptorCalls.contains(call.calledExpression.trimmedDescription) {
                guard let operation = call.arguments.first?.expression else { return false }
                let names = Set(operation.tokens(viewMode: .sourceAccurate).map(\.text))
                return names.contains("kCCDecrypt") && !names.contains("kCCEncrypt")
            }
            current = candidate.parent
        }
        return false
    }

    /// Reports a cipher finding, unless it decrypts, or `weakCryptoPolicy` lets a reason stand.
    private func reportCipher(
        _ node: DeclReferenceExprSyntax,
        ruleId: String,
        subject: String,
        message: String,
        suggestedFix: String
    ) {
        guard isRuleEnabled(ruleId), !isInsideLiteralDecrypt(node) else { return }
        let location = node.startLocation(converter: converter)
        reportUnderCryptoPolicy(Diagnostic(
            severity: .error,
            message: message + " " + Self.citation(ruleId),
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: ruleId,
            suggestedFix: suggestedFix
        ))
    }

    // MARK: - weakCryptoPolicy

    /// The marker `weakCryptoPolicy: justified` accepts.
    static let justificationMarker = "// Justification:"

    /// Reports `diagnostic` as `weakCryptoPolicy` says: always, or unless the line above gives a
    /// reason.
    ///
    /// The policy exists for code that reads a format somebody else designed — *"a reader either
    /// computes SHA-1 or refuses to open the document"*, and the same holds for AES-ECB in an
    /// `.itl` file. It governs `weak-crypto`, `broken-cipher` and `ecb-mode` alike. A reason must
    /// pass ``JustificationValidator`` — the bar `// SECURITY:` is held to — and an accepted one
    /// is recorded as an override, so it is visible in every report rather than silent.
    func reportUnderCryptoPolicy(_ diagnostic: Diagnostic) {
        switch configuration.weakCryptoPolicy.verdict(in: (), evidence: ()) {
        case .count, .report:
            // `.count` is not reachable — the policy offers no aggregate level, deliberately.
            // Reporting is the safe reading if one is ever added without revisiting this.
            report(diagnostic)
        case .requireJustification:
            guard let line = diagnostic.lineNumber, let ruleId = diagnostic.ruleId,
                  line >= 2, line - 2 < sourceLines.count,
                  let range = sourceLines[line - 2].range(of: Self.justificationMarker) else {
                report(Self.appending(
                    " Add a `// Justification:` comment on the line above saying why it is dictated "
                        + "rather than chosen.", to: diagnostic))
                return
            }
            let text = String(sourceLines[line - 2][range.lowerBound...])
            switch justificationValidator.validate(text, keyword: Self.justificationMarker) {
            case .valid:
                overrides.append(DiagnosticOverride(
                    ruleId: ruleId,
                    justification: text[range.upperBound...].trimmingCharacters(in: .whitespaces),
                    filePath: fileName,
                    lineNumber: line))
            case .tooShort(let wordCount):
                report(Self.appending(
                    " (The `// Justification:` on line \(line - 1) was not accepted: \(wordCount) "
                        + "word\(wordCount == 1 ? "" : "s"), 8 required.)", to: diagnostic))
            case .generic(let phrase):
                report(Self.appending(
                    " (The `// Justification:` on line \(line - 1) was not accepted: '\(phrase)' "
                        + "is a generic phrase, not a reason.)", to: diagnostic))
            case .duplicate:
                // `validate` never answers this; only `validateForDuplicates` does.
                report(diagnostic)
            }
        }
    }

    /// `diagnostic` with `suffix` appended to its message.
    private static func appending(_ suffix: String, to diagnostic: Diagnostic) -> Diagnostic {
        Diagnostic(
            severity: diagnostic.severity,
            message: diagnostic.message + suffix,
            filePath: diagnostic.filePath,
            lineNumber: diagnostic.lineNumber,
            columnNumber: diagnostic.columnNumber,
            ruleId: diagnostic.ruleId,
            suggestedFix: diagnostic.suggestedFix,
            origin: diagnostic.origin,
            endLine: diagnostic.endLine)
    }

    // MARK: - homemade-digest (CWE-1240)

    /// Words that, in a function's name, claim a digest or a MAC.
    static let digestWords: Set<String> = [
        "hash", "hashed", "hashing", "digest", "hmac", "mac", "checksum",
    ]

    /// Words that, in a parameter's name, make its value a secret.
    ///
    /// A local list, deliberately narrow. The shared sensitive-name matcher is being unified
    /// separately (`TheGateIsNotYetAggressive.md` §2.1); this rule should move to it when it lands.
    static let secretWords: Set<String> = [
        "password", "passwd", "passphrase", "pin", "secret", "token", "key", "apikey", "credential",
    ]

    /// Identifiers whose presence in a body means a recognised primitive is called.
    ///
    /// The weak ones are here on purpose: a function that hashes a password with MD5 *called a
    /// primitive* — the wrong one — and `weak-crypto` reports it at the call. Reporting it here
    /// too would be two findings for one defect.
    static let primitiveNames: Set<String> = [
        "SHA256", "SHA384", "SHA512", "HMAC", "HKDF", "PBKDF2", "Insecure", "Bcrypt", "BCrypt",
        "Scrypt", "CCHmac", "CCKeyDerivationPBKDF",
        // CryptoSwift's digest extensions on `Data`, `String` and `[UInt8]`.
        "sha1", "sha224", "sha256", "sha384", "sha512", "md5",
    ]

    /// Identifier prefixes that name a primitive family.
    static let primitivePrefixes = ["CC_SHA", "CC_MD5", "Argon2", "argon2", "crypto_pwhash", "crypto_generichash"]

    /// Reports a function named as a digest of a secret whose body calls no primitive.
    ///
    /// A heuristic, and the only one among the cipher rules — so a warning. It was written from
    /// `SwiftMCPServer`'s `hashKey`: documented as SHA-256, a 32-byte XOR fold, on the path that
    /// authenticates API keys. `CC_MD5` would have been flagged; this is weaker and was not,
    /// because it calls nothing.
    func checkHomemadeDigest(_ node: FunctionDeclSyntax) {
        guard isRuleEnabled("security.homemade-digest"), let body = node.body else { return }
        let name = node.name.text
        guard Self.claimsDigest(name) else { return }
        let parameters = Array(node.signature.parameterClause.parameters)
        // `hash(into:)` feeds a `Hasher`; it is `Hashable`, not a digest.
        if name == "hash", parameters.first?.firstName.text == "into" { return }
        guard let secret = parameters.lazy.compactMap(Self.secretParameterName).first,
              !Self.callsPrimitive(body) else { return }

        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: .warning,
            message: "'\(name)' is named as a digest and takes a secret ('\(secret)'), but calls no "
                + "cryptographic primitive. A hand-written fold of a secret is not a hash: it "
                + "can be inverted or collided by hand. \(Self.citation("security.homemade-digest"))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.homemade-digest",
            suggestedFix: "Call SHA256.hash(data:) for a random token or key, HMAC<SHA256> for a MAC, "
                + "or a password KDF (PBKDF2, scrypt, Argon2) for a password."
        ))
    }

    /// Whether a function name claims a digest: a whole word from ``digestWords``, or `sha…`.
    ///
    /// `mac` followed by `address` is a network address, not a MAC.
    static func claimsDigest(_ name: String) -> Bool {
        let words = camelCaseWords(name)
        for (index, word) in words.enumerated() {
            if word == "mac", index + 1 < words.count, words[index + 1] == "address" { continue }
            if digestWords.contains(word) { return true }
            if word.hasPrefix("sha"), word.dropFirst(3).allSatisfy(\.isNumber) { return true }
        }
        return false
    }

    /// The parameter's name, if either its label or its local name is secret-named.
    private static func secretParameterName(_ parameter: FunctionParameterSyntax) -> String? {
        let local = parameter.secondName?.text ?? parameter.firstName.text
        for candidate in [parameter.firstName.text, local] where candidate != "_" {
            if camelCaseWords(candidate).contains(where: secretWords.contains) { return local }
        }
        return nil
    }

    /// Whether `body` names a recognised primitive, or delegates to another digest-named function.
    ///
    /// Read from identifier tokens, not text: `hashKey`'s comments mention "bcrypt", "Argon2" and
    /// "SHA-256", and comments call nothing. A call to another function that itself claims a
    /// digest is delegation; that function is examined on its own.
    private static func callsPrimitive(_ body: CodeBlockSyntax) -> Bool {
        for token in body.tokens(viewMode: .sourceAccurate) {
            guard case .identifier(let text) = token.tokenKind else { continue }
            if primitiveNames.contains(text) || primitivePrefixes.contains(where: text.hasPrefix) {
                return true
            }
            if claimsDigest(text), isCallee(token) { return true }
        }
        return false
    }

    /// Whether `token` is the name a call is made through — `digest(…)` or `x.digest(…)`.
    private static func isCallee(_ token: TokenSyntax) -> Bool {
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return false }
        var callee = Syntax(reference)
        if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id {
            callee = Syntax(member)
        }
        guard let call = callee.parent?.as(FunctionCallExprSyntax.self) else { return false }
        return call.calledExpression.id == callee.id
    }
}
