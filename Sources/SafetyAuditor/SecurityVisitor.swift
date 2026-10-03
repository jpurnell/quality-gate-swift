import Foundation
import QualityGateCore
import SwiftSyntax

/// Scans Swift source for OWASP Mobile Top 10 security vulnerabilities.
///
/// Uses SwiftSyntax AST walking for higher precision than tree-sitter scanners.
/// Key differentiator: context-aware — won't flag string interpolation in
/// `fatalError`, `print`, doc comments, or other non-security-relevant contexts.
///
/// ## Rules
///
/// | Rule ID | CWE | What it detects |
/// |---------|-----|-----------------|
/// | `security.hardcoded-secret` | 798 | Secret-named variable with string literal value |
/// | `security.command-injection` | 78 | Process/NSTask with dynamic arguments |
/// | `security.weak-crypto` | 328 | CC_MD5, CC_SHA1, Insecure.* hash calls |
/// | `security.broken-cipher` | 327 | DES/3DES/RC4/RC2/CAST/Blowfish constants; CryptoSwift Blowfish, Rabbit |
/// | `security.ecb-mode` | 327 | kCCOptionECBMode, kCCModeECB; CryptoSwift ECB |
/// | `security.homemade-digest` | 1240 | Digest-named function of a secret that calls no primitive |
/// | `security.hardcoded-key` | 321 | Literal key bytes to SymmetricKey, CCCrypt/CCHmac, a PrivateKey; a PEM private key — see `SecurityVisitor+Keys.swift` |
/// | `security.static-iv` | 329, 1204, 323 | nil or literal IV when encrypting; literal or held AEAD nonce |
/// | `security.weak-kdf` | 916 | PBKDF2 below 210,000 rounds; unchecked PBKDF2; a bare digest of a password |
/// | `security.weak-key-size` | 326 | RSA below 2048 bits, symmetric key below 128 bits |
/// | `security.insecure-transport` | 319 | http:// URLs (excluding localhost) |
/// | `security.eval-js` | 95 | evaluateJavaScript with non-literal argument |
/// | `security.sql-injection` | 89 | Interpolation in SQL-executing function call |
/// | `security.insecure-keychain` | 922 | Deprecated keychain accessibility constants |
/// | `security.tls-disabled` | 295, 298 | Certificate validation switched off — see `SecurityVisitor+Trust.swift` |
/// | `security.tls-no-hostname` | 297 | Certificate not checked against the host |
/// | `security.trust-handler-accepts-all` | 295 | Trust challenge answered without an evaluation |
/// | `security.trust-anchors-widened` | 295 | Built-in anchors re-enabled after pinning (warning) |
/// | `security.path-traversal` | 22 | Chosen segment joined onto a directory and used without containment |
/// | `security.ssrf` | 918 | URL(string:) with non-literal argument |
/// | `security.xml-external-entities` | 611 | XML parser configured, or defaulted, to load external entities |
/// | `security.xml-entity-expansion` | 776 | `XML_PARSE_HUGE`; `XMLDocument` parse with no DTD refusal (warning) |
/// | `security.path-containment-by-prefix` | 22, 187 | `hasPrefix` containment check with no separator |
/// | `security.archive-path-escape` | 22 | Archive entry name joined and written without containment; `unzip -:`, `tar -P` |
/// | `security.archive-symlink` | 59 | Link target chosen by an archive entry, unchecked; ZIPFoundation containment switched off |
/// | `security.weak-prng` | 338 | C `rand` family or GameplayKit making a security value — see `SecurityVisitor+Randomness.swift` |
/// | `security.seeded-secret` | 335, 336, 337 | Security value drawn from a generator seeded in the same function |
/// | `security.predictable-token` | 341 | Security value made only of the clock, the pid or a hash value |
/// | `security.uuid-as-secret` | 340 | Security value made of `UUID()` (warning) |
final class SecurityVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    let sourceLines: [String]
    let configuration: SecurityAuditorConfig
    /// Built once per file — see `SafetyVisitor.converter`.
    let converter: SourceLocationConverter
    /// Names bound by a `let` in this file whose initialiser is a plain string literal.
    ///
    /// Collected up front rather than during the walk: a constant may be declared below
    /// the call that interpolates it, and a set built as we go would depend on source
    /// order for its answer.
    let localStringConstants: Set<String>
    var diagnostics: [Diagnostic] = []
    var overrides: [DiagnosticOverride] = []
    /// XML parse sites seen in this file, for the `security.xml-coverage` note.
    var xmlSites = XMLSiteCounts()
    /// What the randomness rules examined in this file, for the `security.randomness-coverage` note.
    var randomnessSites = RandomnessSiteCounts()
    /// Holds `// SECURITY:` reasons to the bar `concurrency.*` justifications already meet.
    let justificationValidator = JustificationValidator()
    /// `secretPatterns` as terms for ``SensitiveName`` — built once per file, not per binding.
    private let secretPatternTerms: [SensitiveName.Term]
    /// The type of the target owning this file. The key rules (`SecurityVisitor+Keys.swift`) do
    /// not report in a test target, where fixed key material is a known-answer vector.
    let targetType: TargetType
    /// `let` bindings whose literal `security.hardcoded-key` reported at a use as key material.
    var claimedKeyBindings: Set<SyntaxIdentifier> = []
    /// `security.hardcoded-secret` findings held until the file is walked, so one that
    /// `hardcoded-key` claims is not reported twice — see ``visitPost(_:)``.
    private var pendingSecrets: [(binding: SyntaxIdentifier, diagnostic: Diagnostic)] = []

    init(
        fileName: String,
        source: String,
        converter: SourceLocationConverter,
        configuration: SecurityAuditorConfig,
        sourceFile: SourceFileSyntax? = nil,
        targetType: TargetType = .executable
    ) {
        self.targetType = targetType
        self.localStringConstants = sourceFile.map(Self.stringLiteralConstants(in:)) ?? []
        self.fileName = fileName
        self.source = source
        self.converter = converter
        self.sourceLines = source.lines
        self.configuration = configuration
        self.secretPatternTerms = configuration.secretPatterns.map { SensitiveName.customTerm($0) }
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Source File Visitor (randomness — SecurityVisitor+Randomness.swift)

    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        checkRandomness(in: node)
        return .visitChildren
    }

    // MARK: - Variable Declaration Visitor

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        checkTypedCertificateVerification(node)
        guard isRuleEnabled("security.hardcoded-secret") else {
            return .visitChildren
        }

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }

            // Whole words, through the gate's one sensitive-name matcher. This was
            // `name.lowercased().contains(pattern)`, which made `tokenizer` and `secretary`
            // credentials (`PublicIsAClaimAboutTheValue.md` §4.4). The rule keeps the words it
            // shipped with: the union vocabulary added nineteen findings across the portfolio,
            // all header names, grant-type constants and test fixtures, so widening it is left
            // to a change that measures and argues for it.
            let classification = SensitiveName.classify(
                pattern.identifier.text,
                restrictedTo: .hardcodedSecretRule,
                additionalTerms: secretPatternTerms)
            guard classification.namesSecret else { continue }

            // Check if assigned a string literal
            guard let initializer = binding.initializer,
                  let literal = initializer.value.as(StringLiteralExprSyntax.self) else {
                continue
            }
            // A PEM private key is key material: `hardcoded-key` reports the literal itself.
            if keyRulesApply, isRuleEnabled("security.hardcoded-key"), Self.isPEMPrivateKey(literal) { continue }

            let location = node.startLocation(
                converter: converter
            )
            pendingSecrets.append((pattern.id, Diagnostic(
                severity: .warning,
                message: "Hardcoded secret or credential detected in '\(pattern.identifier.text)'. [CWE-798]",
                filePath: fileName,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: "security.hardcoded-secret",
                suggestedFix: "Load secrets from environment variables, keychain, or a secure configuration provider"
            )))
        }

        return .visitChildren
    }

    /// Reports the `hardcoded-secret` findings that `hardcoded-key` did not claim.
    ///
    /// One literal, one finding. `hardcoded-secret` (CWE-798) reads a *name*: a secret-named
    /// binding assigned a string literal. `hardcoded-key` (CWE-321, a child of 798) reads a *use*:
    /// literal bytes passed where a cipher, MAC or key initialiser takes its key. When a
    /// secret-named literal is that key, the more specific rule reports it at the use, and this
    /// one stays quiet. Held to the end of the file because the use may come after, or before,
    /// the declaration.
    override func visitPost(_ node: SourceFileSyntax) {
        for pending in pendingSecrets where !claimedKeyBindings.contains(pending.binding) {
            report(pending.diagnostic)
        }
        pendingSecrets.removeAll()
    }

    // MARK: - Function Call Visitor

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // No `checkCommandInjection` here any more. It matched `callee == "Process"`, which is
        // a construction site rather than an injection, and that signal now belongs to
        // `bounded-io.process-construction`. The rule moved to the assignment visitor, where
        // the arguments it is named for are actually visible.
        checkWeakCrypto(node)
        checkEvalJS(node)
        checkSQLInjection(node)
        checkSSRF(node)
        checkPathTraversal(node)
        checkPathContainmentByPrefix(node)
        checkArchivePathEscape(node)
        checkArchiveSymlink(node)
        checkCertificateVerificationArguments(node)
        checkTrustCalls(node)
        checkVerifyBlock(node)
        checkKeyArguments(node)
        countXMLParseSite(node)
        for finding in XMLEntityRules.call(node) { reportXML(finding) }
        return .visitChildren
    }

    // MARK: - Reference Visitor (broken cipher, ECB, XML entities)

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        checkCipherReference(node)
        checkKeySizeAttribute(node)
        checkDisabledEvaluator(node)
        if let finding = XMLEntityRules.reference(node) { reportXML(finding) }
        return .visitChildren
    }

    // MARK: - Function Declaration Visitor (homemade digest, XML resolver delegate)

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        checkHomemadeDigest(node)
        checkTrustHandler(node)
        if let finding = XMLEntityRules.function(node) { reportXML(finding) }
        return .visitChildren
    }

    // MARK: - XML entities (CWE-611, CWE-776)

    private var xmlRulesEnabled: Bool {
        isRuleEnabled(XMLEntityRules.externalRule) || isRuleEnabled(XMLEntityRules.expansionRule)
    }

    /// Counts a parse site whether or not anything is wrong with it: the note's denominator.
    private func countXMLParseSite(_ node: FunctionCallExprSyntax) {
        guard xmlRulesEnabled else { return }
        if XMLEntityRules.isXMLParserConstruction(node) {
            xmlSites.xmlParser += 1
        } else if XMLEntityRules.isParsingXMLDocument(node) {
            xmlSites.xmlDocument += 1
        } else if XMLEntityRules.isLibxml2Parse(node) {
            xmlSites.libxml2 += 1
        }
    }

    /// Locates an XML finding and sends it through `report(_:)`, so its acknowledgement is
    /// validated and recorded like every other security rule's.
    private func reportXML(_ finding: XMLEntityFinding) {
        guard isRuleEnabled(finding.ruleId) else { return }
        if finding.configuresExternalLoad { xmlSites.configuredToLoad += 1 }
        let location = finding.anchor.startLocation(converter: converter)
        report(Diagnostic(
            severity: finding.severity,
            message: finding.message,
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: finding.ruleId,
            suggestedFix: finding.suggestedFix
        ))
    }

    // MARK: - String Literal Visitor (insecure transport)

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        checkPrivateKeyLiteral(node)
        guard isRuleEnabled("security.insecure-transport") else {
            return .visitChildren
        }

        // Only check simple string literals, not interpolated ones
        guard node.segments.count == 1,
              let segment = node.segments.first?.as(StringSegmentSyntax.self) else {
            return .visitChildren
        }

        let text = segment.content.text
        guard text.hasPrefix("http://") else { return .visitChildren } // SAFETY: Pattern-match string, not an actual HTTP request

        // Extract host from URL
        let afterScheme = text.dropFirst("http://".count) // SAFETY: Pattern-match string, not an actual HTTP request
        let host = String(afterScheme.prefix(while: { $0 != "/" && $0 != ":" && $0 != "?" }))

        // A bare scheme names no host, so it cannot be an endpoint.
        //
        // `"http://"` exists for exactly one purpose — deciding whether some *other* string
        // is a URL, as in `text.hasPrefix("http://")`. Flagging it asks for `https://`,
        // which would break the very check that tells insecure URLs from secure ones: the
        // rule demanding its own defeat.
        guard !host.isEmpty else { return .visitChildren }

        // Allow configured safe hosts
        guard !configuration.allowedHTTPHosts.contains(host) else {
            return .visitChildren
        }

        // Allow XML namespace URIs, which are names rather than endpoints.
        //
        // A namespace URI identifies a vocabulary; W3C states it need not be
        // dereferenceable, and OOXML, SVG and XHTML all mandate the `http://` form.
        // Rewriting one to `https` changes the document's meaning, so flagging it asks
        // for a change that would be wrong — the rule would be demanding a defect.
        //
        // The discriminator is CONTEXT, not the string: the same URI is a name inside a
        // comparison and an endpoint inside `URL(string:)`. Only the former is exempt,
        // so a genuine http request to one of these domains is still reported.
        if Self.namespaceIdentifierHosts.contains(host), !isURLConstruction(node) {
            return .visitChildren
        }

        let location = node.startLocation(
            converter: converter
        )
        report(Diagnostic(
            severity: .warning,
            message: "Insecure HTTP URL detected — use HTTPS instead. [CWE-319]",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.insecure-transport",
            suggestedFix: "Replace http:// with https://"
        ))

        return .visitChildren
    }

    /// Domains that publish XML/RDF namespace vocabularies.
    ///
    /// URIs on these hosts are used as identifiers in documents and comparisons. They
    /// are not exempt when actually used to build a `URL`.
    static let namespaceIdentifierHosts: Set<String> = [
        "schemas.openxmlformats.org",
        "schemas.microsoft.com",
        "www.w3.org",
        "purl.org",
        "xmlns.com",
        "docs.oasis-open.org",
        "ns.adobe.com",
        "iptc.org"
    ]

    /// Whether this literal is an argument to a `URL` initialiser.
    ///
    /// Walks a bounded number of parents: a string used to construct a URL is an
    /// endpoint whatever its host, while the same characters compared against document
    /// text are a name.
    private func isURLConstruction(_ node: StringLiteralExprSyntax) -> Bool {
        var current: Syntax? = Syntax(node).parent
        var depth = 0
        while let candidate = current, depth < 4 {
            if let call = candidate.as(FunctionCallExprSyntax.self) {
                let callee = call.calledExpression.trimmedDescription
                if callee == "URL" || callee.hasSuffix(".URL")
                    || callee == "URLRequest" || callee.hasSuffix(".URLRequest") {
                    return true
                }
            }
            current = candidate.parent
            depth += 1
        }
        return false
    }

    // MARK: - Member Access Visitor (keychain, TLS)

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        checkInsecureKeychain(node)
        checkTLSDisabled(node)
        if let finding = XMLEntityRules.memberAccess(node) { reportXML(finding) }
        return .visitChildren
    }

    // MARK: - Sequence Expression Visitor (TLS disabled via assignment)
    // Note: SwiftSyntax in source-accurate mode produces SequenceExprSyntax
    // for assignments (not InfixOperatorExprSyntax, which requires folding).

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        checkTLSAssignment(node)
        checkCertificateVerificationAssignment(node)
        if let finding = XMLEntityRules.assignment(node) { reportXML(finding) }
        // Order matters and follows source order: the executable is assigned before the
        // arguments in every shape this rule recognises.
        noteExecutableAssignment(node)
        checkShellCommandAssembly(node)
        noteExtractorAssignment(node)
        checkExtractorFlags(node)
        return .visitChildren
    }

    // MARK: - Rule Implementations

    // MARK: Command Injection (CWE-78)

    /// Shell interpreters, by executable base name.
    ///
    /// The list is the point of the rule: injection needs an interpreter. A `Process` given an
    /// `arguments` array invokes none — each element arrives as one `argv` entry, so a filename
    /// containing `; rm -rf /` is passed as a filename and nothing parses it.
    static let shellNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish"
    ]

    /// Flags that make the *next* argument a program to parse rather than a file to read.
    private static let commandFlags: Set<String> = ["-c", "-lc", "-ic", "--command"]

    /// Variables whose executable has been set to a shell, by base identifier.
    ///
    /// Correlated by identifier rather than by proximity: two unrelated spawns in one function
    /// would otherwise borrow each other's executable, and the false positive would land on
    /// whichever happened to be written second.
    private var shellVariables: Set<String> = []

    /// Variables whose executable is an archive extractor, by base identifier, to the tool's
    /// name (`unzip`, `tar`). Correlated the same way as `shellVariables`.
    var extractorVariables: [String: String] = [:]

    /// Records `x.executableURL = URL(fileURLWithPath: "/bin/sh")` and `x.launchPath = "/bin/sh"`.
    ///
    /// Called for every assignment; only shell paths are retained.
    func noteExecutableAssignment(_ node: SequenceExprSyntax) {
        guard let (base, path) = Self.executableAssignment(node) else { return }
        let name = (path as NSString).lastPathComponent
        // `env` defers the choice of interpreter to its first argument, so the decision moves to
        // the argument array; treating it as a shell here is what makes `env sh -c` reachable.
        if Self.shellNames.contains(name) || name == "env" {
            shellVariables.insert(base)
        }
    }

    /// `x.executableURL = URL(fileURLWithPath: "/bin/sh")` or `x.launchPath = "/bin/sh"`: the
    /// variable and the literal path.
    static func executableAssignment(_ node: SequenceExprSyntax) -> (String, String)? {
        let elements = Array(node.elements)
        guard elements.count >= 3,
              elements[1].is(AssignmentExprSyntax.self),
              let member = elements[0].as(MemberAccessExprSyntax.self),
              let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text else { return nil }
        let property = member.declName.baseName.text
        guard property == "executableURL" || property == "launchPath",
              let path = firstStringLiteral(in: elements[2]) else { return nil }
        return (base, path)
    }

    /// The command-injection rule proper: a shell handed a command string it did not author.
    ///
    /// Fires only when a shell is named, a command flag is present, and the argument after that
    /// flag is not a literal. Each condition alone is a false positive: shells legitimately run
    /// literal scripts; `-c` is also `git -c user.name=…` and `swift build -c release`, neither
    /// of which is a shell; and interpolation into an `argv` element is ordinary.
    ///
    /// Deliberately no taint tracking. Whether the interpolated value is attacker-controlled is
    /// not decidable in one file, and a single-file visitor that pretends otherwise reports
    /// confident nonsense — the conclusion the `liveness` work already reached. Interpolating
    /// any value into a shell command is the finding; a safe one is acknowledged with
    /// `// SECURITY:`, not silently permitted.
    func checkShellCommandAssembly(_ node: SequenceExprSyntax) {
        guard isRuleEnabled("security.command-injection") else { return }
        let elements = Array(node.elements)
        guard elements.count >= 3,
              elements[1].is(AssignmentExprSyntax.self),
              let member = elements[0].as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "arguments",
              let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text,
              let array = elements[2].as(ArrayExprSyntax.self) else { return }

        let items = Array(array.elements)
        var isShell = shellVariables.contains(base)

        // `env sh -c …`: the interpreter is the first argument, not the executable.
        if let first = items.first,
           let name = first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue,
           Self.shellNames.contains((name as NSString).lastPathComponent) {
            isShell = true
        }
        guard isShell else { return }

        for (index, item) in items.enumerated() {
            guard let flag = item.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue,
                  Self.commandFlags.contains(flag),
                  index + 1 < items.count else { continue }

            let command = items[index + 1].expression
            // A literal script assembled nothing and is not this rule's business.
            guard Self.isNonLiteral(command) else { continue }

            let location = command.startLocation(
                converter: converter)
            report(Diagnostic(
                severity: .error,
                message: "A shell is invoked with \(flag) and a command string assembled at "
                    + "runtime. The shell parses that string, so any value interpolated into it "
                    + "can end the command and start another. [CWE-78]",
                filePath: fileName,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: "security.command-injection",
                suggestedFix: "Pass the program and its arguments as separate array elements "
                    + "without a shell — argv entries are not parsed — or acknowledge with "
                    + "// SECURITY: <reason> if a shell is genuinely required."
            ))
            return
        }
    }

    /// Whether `expression` is anything other than a string literal with no interpolation.
    private static func isNonLiteral(_ expression: ExprSyntax) -> Bool {
        guard let literal = expression.as(StringLiteralExprSyntax.self) else {
            // An identifier or a call: the command was assembled elsewhere, which is worse.
            return true
        }
        return literal.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
    }

    /// The first string literal inside `expression`, unwrapping one call layer.
    ///
    /// Unwraps so `URL(fileURLWithPath: "/bin/sh")` yields the path the same as a bare literal.
    static func firstStringLiteral(in expression: ExprSyntaxProtocol) -> String? {
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return literal.representedLiteralValue
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            for argument in call.arguments {
                if let literal = argument.expression.as(StringLiteralExprSyntax.self) {
                    return literal.representedLiteralValue
                }
            }
        }
        return nil
    }

    // MARK: Weak Crypto (CWE-328)

    private func checkWeakCrypto(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.weak-crypto") else { return }

        let callee: String
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            callee = ref.baseName.text
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            // Check for Insecure.MD5.hash(...), Insecure.SHA1.hash(...)
            // AST: MemberAccess(base: MemberAccess(base: "Insecure", "MD5"), "hash")
            if let innerMember = member.base?.as(MemberAccessExprSyntax.self),
               let base = innerMember.base?.as(DeclReferenceExprSyntax.self),
               base.baseName.text == "Insecure" {
                let algorithm = innerMember.declName.baseName.text
                if algorithm == "MD5" || algorithm == "SHA1" {
                    emitWeakCryptoDiagnostic(node, algorithm: "Insecure.\(algorithm)")
                }
            }
            // Also check direct Insecure.MD5(...) or Insecure.SHA1(...)
            if let base = member.base?.as(DeclReferenceExprSyntax.self),
               base.baseName.text == "Insecure" {
                let method = member.declName.baseName.text
                if method == "MD5" || method == "SHA1" {
                    emitWeakCryptoDiagnostic(node, algorithm: "Insecure.\(method)")
                }
            }
            return
        } else {
            return
        }

        let weakFunctions = ["CC_MD5", "CC_SHA1", "CC_MD5_Init", "CC_MD5_Update",
                             "CC_MD5_Final", "CC_SHA1_Init", "CC_SHA1_Update", "CC_SHA1_Final"]
        guard weakFunctions.contains(callee) else { return }

        emitWeakCryptoDiagnostic(node, algorithm: callee)
    }

    /// Whether a weak hash is a defect depends on what it is for. Deriving a key for a file
    /// format that names SHA-1 is not a security choice — the alternative is refusing to open
    /// the file — and no property of the surrounding code says so. A stated reason does, which
    /// is what `weakCryptoPolicy: justified` asks for; ``reportUnderCryptoPolicy(_:)`` decides.
    private func emitWeakCryptoDiagnostic(_ node: FunctionCallExprSyntax, algorithm: String) {
        let location = node.startLocation(
            converter: converter
        )
        reportUnderCryptoPolicy(Diagnostic(
            severity: .warning,
            message: "Use of weak cryptographic hash '\(algorithm)'. \(Self.citation("security.weak-crypto"))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.weak-crypto",
            suggestedFix: "Use SHA256 or stronger from CryptoKit: SHA256.hash(data:)"
        ))
    }

    // MARK: Eval JS (CWE-95)

    private func checkEvalJS(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.eval-js") else { return }

        // Check for .evaluateJavaScript(...) calls
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "evaluateJavaScript" else {
            return
        }

        // If the first argument is a simple string literal, it's safe
        if let firstArg = node.arguments.first,
           firstArg.expression.is(StringLiteralExprSyntax.self) {
            // Check if the string literal has interpolation segments
            if let literal = firstArg.expression.as(StringLiteralExprSyntax.self),
               !containsInterpolation(literal) {
                return // Pure string literal — safe
            }
        }

        let location = node.startLocation(
            converter: converter
        )
        report(Diagnostic(
            severity: .error,
            message: "evaluateJavaScript called with dynamic input — enables code injection. [CWE-95]",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.eval-js",
            suggestedFix: "Use WKUserContentController.addUserScript or callAsyncJavaScript with parameterized arguments"
        ))
    }

    // MARK: SQL Injection (CWE-89)

    /// C-level SQLite API names that are unambiguous — always flag regardless of receiver.
    private static let alwaysFlagSQLNames: Set<String> = [
        "sqlite3_exec", "sqlite3_prepare", "sqlite3_prepare_v2",
        "sqlite3_prepare_v3", "sqlite3_prepare16", "rawQuery"
    ]

    /// Receiver name substrings that indicate a database context.
    /// Generic function names (execute, prepare, query) are only flagged when
    /// called on a receiver whose lowercased name contains one of these.
    private static let dbReceiverPatterns: [String] = [
        "db", "database", "sql", "sqlite", "connection", "conn",
        "statement", "stmt", "cursor", "pool", "grdb", "fluent",
        "mysql", "postgres", "pg", "mongo", "redis", "query"
    ]

    private func checkSQLInjection(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.sql-injection") else { return }

        // Get the function name and optional receiver
        let funcName: String
        let receiverName: String?
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            funcName = member.declName.baseName.text
            receiverName = member.base?.description
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        } else if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            funcName = ref.baseName.text
            receiverName = nil
        } else {
            return
        }

        // Only check known SQL-executing functions
        guard configuration.sqlFunctionNames.contains(funcName) else { return }

        // For unambiguous C-API names, always flag regardless of receiver
        let isUnambiguousSQL = Self.alwaysFlagSQLNames.contains(funcName)

        if !isUnambiguousSQL {
            // Generic names (execute, prepare, query) need DB-related receiver context
            guard let receiver = receiverName else { return }
            let looksLikeDB = Self.dbReceiverPatterns.contains { receiver.contains($0) }
            guard looksLikeDB else { return }
        }

        // Check if any argument contains string interpolation
        for arg in node.arguments {
            guard let literal = arg.expression.as(StringLiteralExprSyntax.self),
                  containsInterpolation(literal) else {
                continue
            }

            let location = node.startLocation(
                converter: converter
            )
            report(Diagnostic(
                severity: .error,
                message: "SQL query with string interpolation — use parameterized queries. [CWE-89]",
                filePath: fileName,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: "security.sql-injection",
                suggestedFix: "Use parameterized queries with ? placeholders instead of string interpolation"
            ))
            return // One diagnostic per call site
        }
    }

    // MARK: Local string constants

    /// Names bound by a `let` whose initialiser is a string literal with no interpolation.
    ///
    /// `var` is excluded deliberately: it may be reassigned, and a rule that treats
    /// today's literal as a permanent one would stop firing the day someone assigns to it.
    /// A constant built from its own interpolation is excluded for the same reason — it is
    /// only as constant as whatever it was built from, which this does not chase.
    static func stringLiteralConstants(in file: SourceFileSyntax) -> Set<String> {
        var names: Set<String> = []
        collectStringLiteralConstants(Syntax(file), into: &names)
        return names
    }

    private static func collectStringLiteralConstants(_ node: Syntax, into names: inout Set<String>) {
        if let decl = node.as(VariableDeclSyntax.self), decl.bindingSpecifier.tokenKind == .keyword(.let) {
            for binding in decl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      let value = binding.initializer?.value.as(StringLiteralExprSyntax.self),
                      !value.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else {
                    continue
                }
                names.insert(pattern.identifier.text)
            }
        }
        for child in node.children(viewMode: .sourceAccurate) {
            collectStringLiteralConstants(child, into: &names)
        }
    }

    /// Whether every interpolation in `literal` resolves to a constant declared in this file.
    ///
    /// Accepts a bare name (`allowedHost`) and a one-step qualification (`Self.allowedHost`,
    /// `Config.allowedHost`) where the trailing name is a known local constant. Anything
    /// else — a call, a subscript, a deeper path — is not resolved and so is not trusted.
    private func interpolationsAreAllLocalConstants(_ literal: StringLiteralExprSyntax) -> Bool {
        var sawInterpolation = false
        for segment in literal.segments {
            guard let expression = segment.as(ExpressionSegmentSyntax.self) else { continue }
            sawInterpolation = true
            guard let only = expression.expressions.first,
                  expression.expressions.count == 1,
                  let name = constantName(of: only.expression),
                  localStringConstants.contains(name) else {
                return false
            }
        }
        return sawInterpolation
    }

    /// The identifier an expression names, if it is a bare reference or a one-step member access.
    private func constantName(of expression: ExprSyntax) -> String? {
        if let ref = expression.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = expression.as(MemberAccessExprSyntax.self),
           let base = member.base,
           base.is(DeclReferenceExprSyntax.self) {
            return member.declName.baseName.text
        }
        return nil
    }

    // MARK: SSRF (CWE-918)

    private func checkSSRF(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.ssrf") else { return }

        // Check for URL(string: <non-literal>)
        guard let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
              ref.baseName.text == "URL" else {
            return
        }

        guard let firstArg = node.arguments.first,
              firstArg.label?.text == "string" else {
            return
        }

        // If the argument is a plain string literal without interpolation, it's safe
        if let literal = firstArg.expression.as(StringLiteralExprSyntax.self),
           !containsInterpolation(literal) {
            return
        }

        // So is one whose every interpolation resolves to a string constant declared in
        // this file: there is no dynamic input in it, and the suggested fix — validate
        // against an allowlist — cannot be applied to a value that is already a literal.
        if let literal = firstArg.expression.as(StringLiteralExprSyntax.self),
           interpolationsAreAllLocalConstants(literal) {
            return
        }

        let location = node.startLocation(
            converter: converter
        )
        report(Diagnostic(
            severity: .warning,
            message: "URL constructed from dynamic input — potential SSRF. [CWE-918]",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.ssrf",
            suggestedFix: "Validate the URL against an allowlist of expected hosts before making requests"
        ))
    }

    // MARK: Path Traversal (CWE-22)

    /// Operations that read, write, list, create or remove what a path names.
    ///
    /// `fileExists` and `attributesOfItem` used to be here. A probe opens nothing, and in the
    /// gate's own source they were most of 238 findings that described no traversal.
    private static let pathSinks: Set<String> = [
        "contents", "contentsOfDirectory", "createDirectory", "createFile",
        "removeItem", "copyItem", "moveItem",
    ]

    /// Traversal is a join: a segment somebody else chose, appended to a directory, then used.
    ///
    /// A path received whole is the caller's and is not reported here — nothing was joined in
    /// this function. A join is reported unless a sound containment check on the joined value
    /// comes first. See `TraversalIsAJoin.md`.
    private func checkPathTraversal(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.path-traversal"),
              let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              Self.pathSinks.contains(member.declName.baseName.text),
              let argument = node.arguments.first(where: {
                  $0.label?.text == "atPath" || $0.label?.text == "path"
              }) else { return }

        let core = Self.strippingPathAccessors(argument.expression)
        var subject: String?
        var joined = core
        if let name = core.as(DeclReferenceExprSyntax.self)?.baseName.text,
           let initialiser = Self.letInitialiser(named: name, before: node) {
            subject = name
            joined = Self.strippingPathAccessors(initialiser)
        }
        guard Self.isJoinWithChosenSegment(joined, at: node) else { return }
        if let subject, hasSoundContainmentCheck(on: subject, before: node) { return }
        // One defect, one diagnostic: an archive entry's name escaping is the more specific report.
        if isRuleEnabled(Self.archiveEscapeRule), let join = joined.as(FunctionCallExprSyntax.self),
           archiveEscape(of: join) != nil { return }

        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: .warning,
            message: "A path segment that is not a literal is joined onto a directory and the result is "
                + "used without a containment check. A segment of '..' or an absolute path walks out of "
                + "the directory. [CWE-22]",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.path-traversal",
            suggestedFix: "Before using it, check the joined path with pathComponents.starts(with:) after "
                + "resolvingSymlinksInPath(), or a function listed in security.containmentCheckers."
        ))
    }

    /// `x.path`, `x.standardizedFileURL`, `x.resolvingSymlinksInPath()` … down to `x`.
    static func strippingPathAccessors(_ expression: ExprSyntax) -> ExprSyntax {
        let accessors: Set<String> = [
            "path", "standardized", "standardizedFileURL", "resolvingSymlinksInPath", "absoluteURL",
        ]
        var current = expression
        // Bounded: a chain longer than this is not a path accessor chain anyone writes.
        for _ in 0..<8 {
            if let call = current.as(FunctionCallExprSyntax.self), call.arguments.isEmpty,
               let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               accessors.contains(member.declName.baseName.text), let base = member.base {
                current = base
            } else if let member = current.as(MemberAccessExprSyntax.self),
                      accessors.contains(member.declName.baseName.text), let base = member.base {
                current = base
            } else {
                break
            }
        }
        return current
    }

    /// Whether `expression` appends a segment somebody else chose to a directory.
    ///
    /// Only `appendingPathComponent`, `appending(path:)`, `URL(fileURLWithPath:relativeTo:)`, and
    /// `+` or interpolation *after a separator*. `path + ".backup"` extends a file name;
    /// `"\(root)/telemetry"` joins a literal; `a ?? b` joins nothing.
    private static func isJoinWithChosenSegment(_ expression: ExprSyntax, at node: some SyntaxProtocol) -> Bool {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            guard let segment = joinSegment(of: call) else { return false }
            return isChosenSegment(segment, at: node)
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            let operators = elements.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            guard !operators.isEmpty,
                  operators.allSatisfy({ $0.as(BinaryOperatorExprSyntax.self)?.operator.text == "+" }) else {
                return false
            }
            var afterSeparator = false
            for (index, operand) in elements.enumerated() where index % 2 == 0 {
                if let literal = operand.as(StringLiteralExprSyntax.self) {
                    if interpolatesAfterSeparator(literal, startingAfterSeparator: afterSeparator, at: node) {
                        return true
                    }
                    if literal.segments.contains(where: { $0.as(StringSegmentSyntax.self)?.content.text.contains("/") == true }) {
                        afterSeparator = true
                    }
                } else if afterSeparator, isChosenSegment(operand, at: node) {
                    return true
                }
            }
            return false
        }
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return interpolatesAfterSeparator(literal, startingAfterSeparator: false, at: node)
        }
        return false
    }

    /// Whether an interpolation in `literal` follows a `/` — `"\(root)/\(sub)"` but not
    /// `"\(root)/telemetry"`.
    private static func interpolatesAfterSeparator(
        _ literal: StringLiteralExprSyntax, startingAfterSeparator: Bool, at node: some SyntaxProtocol
    ) -> Bool {
        var afterSeparator = startingAfterSeparator
        for segment in literal.segments {
            if let text = segment.as(StringSegmentSyntax.self)?.content.text {
                if text.contains("/") { afterSeparator = true }
            } else if let hole = segment.as(ExpressionSegmentSyntax.self),
                      afterSeparator,
                      let value = hole.expressions.first?.expression,
                      isChosenSegment(value, at: node) {
                return true
            }
        }
        return false
    }

    /// A segment somebody other than this code chose.
    ///
    /// Not a literal; not a loop variable over a collection of literals; not a name just listed
    /// from a directory — `contentsOfDirectory` never returns a name with `/` in it, or `..`.
    static func isChosenSegment(_ expression: ExprSyntax, at node: some SyntaxProtocol) -> Bool {
        if isLiteralSegment(expression) { return false }
        // A generated identifier — `UUID().uuidString`, a process's unique string — contains no
        // separator and nobody outside this code chose it.
        let text = expression.trimmedDescription
        if text.hasPrefix("UUID()") || text.hasSuffix(".globallyUniqueString")
            || text.hasSuffix(".processIdentifier") {
            return false
        }
        guard let name = expression.as(DeclReferenceExprSyntax.self)?.baseName.text else { return true }
        var current = node.parent
        while let candidate = current {
            if let loop = candidate.as(ForStmtSyntax.self), binds(loop.pattern, name) {
                var sequence = loop.sequence
                if let reference = sequence.as(DeclReferenceExprSyntax.self)?.baseName.text,
                   let value = letInitialiser(named: reference, before: loop) {
                    sequence = value
                }
                if sequence.trimmedDescription.contains("contentsOfDirectory(") { return false }
                if let array = sequence.as(ArrayExprSyntax.self),
                   array.elements.allSatisfy({ isLiteralElement($0.expression) }) {
                    return false
                }
                return true
            }
            current = candidate.parent
        }
        return true
    }

    /// Whether a `for` pattern binds `name` — directly or inside a tuple.
    static func binds(_ pattern: PatternSyntax, _ name: String) -> Bool {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) { return identifier.identifier.text == name }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.contains { binds($0.pattern, name) }
        }
        if let binding = pattern.as(ValueBindingPatternSyntax.self) { return binds(binding.pattern, name) }
        return false
    }

    /// A string literal, an integer literal, or a tuple of them.
    private static func isLiteralElement(_ expression: ExprSyntax) -> Bool {
        if isLiteralSegment(expression) { return true }
        if let tuple = expression.as(TupleExprSyntax.self) {
            return tuple.elements.allSatisfy { isLiteralSegment($0.expression) }
        }
        return false
    }

    /// A string literal with no interpolation, or an integer literal.
    static func isLiteralSegment(_ expression: ExprSyntax) -> Bool {
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return !literal.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
        }
        return expression.is(IntegerLiteralExprSyntax.self)
    }

    /// The initialiser of `let name = …` in the enclosing body, before `node`.
    private static func letInitialiser(named name: String, before node: some SyntaxProtocol) -> ExprSyntax? {
        guard let body = enclosingBody(of: node) else { return nil }
        var found: ExprSyntax?
        for declaration in body.tokens(viewMode: .sourceAccurate)
            .compactMap({ $0.parent?.as(IdentifierPatternSyntax.self) })
            where declaration.identifier.text == name && declaration.position < node.position {
            if let binding = declaration.parent?.as(PatternBindingSyntax.self),
               binding.parent?.parent?.as(VariableDeclSyntax.self)?.bindingSpecifier.tokenKind == .keyword(.let),
               let value = binding.initializer?.value {
                found = value
            }
        }
        return found
    }

    /// The function, initialiser, accessor or closure body that `node` sits in.
    static func enclosingBody(of node: some SyntaxProtocol) -> Syntax? {
        var current = node.parent
        while let candidate = current {
            if let function = candidate.as(FunctionDeclSyntax.self) { return function.body.map(Syntax.init) }
            if let initialiser = candidate.as(InitializerDeclSyntax.self) { return initialiser.body.map(Syntax.init) }
            if let accessor = candidate.as(AccessorDeclSyntax.self) { return accessor.body.map(Syntax.init) }
            if let closure = candidate.as(ClosureExprSyntax.self) { return Syntax(closure.statements) }
            current = candidate.parent
        }
        return nil
    }

    /// Whether a `guard` or `if` before `node` checks `subject` soundly for containment.
    ///
    /// Sound means: whole components (`pathComponents.starts(with:)`), `isContained(in:)`, a
    /// prefix test whose argument ends in a separator, or a configured checker. A prefix test
    /// with no separator does not count — `/base-evil` begins with `/base`.
    private func hasSoundContainmentCheck(on subject: String, before node: some SyntaxProtocol) -> Bool {
        guard let body = Self.enclosingBody(of: node) else { return false }
        let collector = ConditionCollector(before: node.position, checkers: configuration.containmentCheckers)
        collector.walk(body)
        // A configured checker called as a statement — `try WriteGuard.confine(p, to: base)` —
        // is as good as one in a condition: it throws instead of returning false.
        if collector.checkerCalls.contains(where: { $0.contains(subject) }) { return true }
        for text in collector.conditions {
            guard text.contains(subject) else { continue }
            if text.contains("pathComponents.starts(with:") || text.contains(".isContained(in:") { return true }
            if configuration.containmentCheckers.contains(where: { text.contains($0 + "(") }) { return true }
            if Self.hasSeparatedPrefixTest(text) { return true }
        }
        return false
    }

    /// `hasPrefix(base + "/")` or `hasPrefix("\(base)/")` — a prefix test with the separator that
    /// makes it a containment test. `hasPrefix("/")` alone is not one.
    static func hasSeparatedPrefixTest(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        return compact.contains("+\"/\")") || compact.range(of: #"hasPrefix\("\\\([^"]*\)/"\)"#, options: .regularExpression) != nil
    }

    // MARK: Path containment by prefix (CWE-22, CWE-187)

    /// A containment check written as a string prefix with no separator.
    ///
    /// `"/runs/out-evil".hasPrefix("/runs/out")` is true, and a prefix test does not follow a
    /// symbolic link. IconquerAI had this four times, VaultMCP and SwiftGraphStore have it, and
    /// two of the comments beside it said "CWE-22 prefix guard".
    private func checkPathContainmentByPrefix(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.path-containment-by-prefix"),
              let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "hasPrefix",
              let receiver = member.base,
              node.arguments.count == 1,
              let argument = node.arguments.first?.expression else { return }
        if Self.isLiteralSegment(argument) { return }
        if Self.hasSeparatedPrefixTest("hasPrefix(" + argument.trimmedDescription + ")") { return }
        if argument.is(DeclReferenceExprSyntax.self) {
            // A loop over literal prefixes (`for p in ["/css/", "/js/"]`) is not containment.
            if !Self.isChosenSegment(argument, at: node) { return }
            // `let prefix = root.hasSuffix("/") ? root : root + "/"` — the separator is in the local.
            if let name = argument.as(DeclReferenceExprSyntax.self)?.baseName.text,
               let value = Self.letInitialiser(named: name, before: node) {
                let compact = value.trimmedDescription.replacingOccurrences(of: " ", with: "")
                if compact.contains("+\"/\"") || compact.range(of: #"/"$"#, options: .regularExpression) != nil {
                    return
                }
            }
        }
        guard Self.isPathShaped(receiver) || Self.isPathShaped(argument),
              Self.isDecision(node) else { return }

        let location = node.startLocation(converter: converter)
        report(Diagnostic(
            severity: .error,
            message: "A path containment check written as a string prefix. '/base-evil' begins with "
                + "'/base', and a prefix test does not follow a symbolic link out of the directory. "
                + "\(Self.citation("security.path-containment-by-prefix"))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.path-containment-by-prefix",
            suggestedFix: "Compare whole components after resolving links: "
                + "candidate.resolvingSymlinksInPath().pathComponents.starts(with: base.resolvingSymlinksInPath().pathComponents)"
        ))
    }

    /// Whether `node` decides something: it is a `guard` / `if` / `while` condition, or the whole
    /// body of a closure (`files.filter { $0.hasPrefix(dir) }`). A ternary that computes a
    /// relative path, or a `return a || b` in a matcher, is arithmetic and is left alone.
    private static func isDecision(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = Syntax(node)
        while let candidate = current {
            if candidate.is(ConditionElementSyntax.self) { return true }
            if candidate.is(TernaryExprSyntax.self) || candidate.is(ReturnStmtSyntax.self)
                || candidate.is(PatternBindingSyntax.self) || candidate.is(CodeBlockItemListSyntax.self) {
                // A closure whose body is this one expression is a predicate.
                if let items = candidate.as(CodeBlockItemListSyntax.self),
                   items.count == 1, items.parent?.is(ClosureExprSyntax.self) == true {
                    return true
                }
                return false
            }
            current = candidate.parent
        }
        return false
    }

    /// An expression that names a path: it ends in `.path`, or its last name says so.
    private static func isPathShaped(_ expression: ExprSyntax) -> Bool {
        let text = expression.trimmedDescription
        if text.hasSuffix(".path") { return true }
        let last = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).last.map(String.init) ?? ""
        // Whole camelCase words: `baseURL` and `rootPath` are paths; `base64SentinelPrefix` is not.
        let pathWords: Set<String> = ["path", "dir", "directory", "root", "base", "url", "folder", "paths", "dirs"]
        return camelCaseWords(last).contains { pathWords.contains($0) }
    }

    /// `baseURLPath` → `["base", "url", "path"]`; `base64Sentinel` → `["base64", "sentinel"]`.
    static func camelCaseWords(_ identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(identifier)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsWord = character.isUppercase && !current.isEmpty
                && (current.last?.isLowercase == true || current.last?.isNumber == true
                    || next?.isLowercase == true)
            if character == "_" {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
                continue
            }
            if startsWord {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    // MARK: Insecure Keychain (CWE-922)

    private func checkInsecureKeychain(_ node: MemberAccessExprSyntax) {
        guard isRuleEnabled("security.insecure-keychain") else { return }

        let insecureConstants = [
            "kSecAttrAccessibleAlways",
            "kSecAttrAccessibleAlwaysThisDeviceOnly"
        ]

        let name = node.declName.baseName.text
        guard insecureConstants.contains(name) else { return }

        let location = node.startLocation(
            converter: converter
        )
        report(Diagnostic(
            severity: .warning,
            message: "Insecure Keychain accessibility level '\(name)' — allows access when device is locked. \(Self.citation("security.insecure-keychain"))",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.insecure-keychain",
            suggestedFix: "Use kSecAttrAccessibleWhenUnlocked or kSecAttrAccessibleAfterFirstUnlock"
        ))
    }

    // MARK: TLS Disabled (CWE-295)

    private func checkTLSDisabled(_ node: MemberAccessExprSyntax) {
        guard isRuleEnabled("security.tls-disabled") else { return }

        let dangerousMembers = ["disableEvaluation"]
        let name = node.declName.baseName.text
        guard dangerousMembers.contains(name) else { return }

        let location = node.startLocation(
            converter: converter
        )
        report(Diagnostic(
            severity: .error,
            message: "TLS certificate validation disabled via '\(name)'. [CWE-295]",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.tls-disabled",
            suggestedFix: "Do not disable certificate evaluation — use proper certificate pinning instead"
        ))
    }

    private func checkTLSAssignment(_ node: SequenceExprSyntax) {
        guard isRuleEnabled("security.tls-disabled") else { return }

        // In source-accurate mode, `a.b = true` is a SequenceExpr with elements:
        // [MemberAccessExpr, AssignmentExpr, BooleanLiteralExpr]
        let elements = Array(node.elements)
        guard elements.count == 3 else { return }

        guard let member = elements[0].as(MemberAccessExprSyntax.self),
              elements[1].is(AssignmentExprSyntax.self),
              let boolLiteral = elements[2].as(BooleanLiteralExprSyntax.self) else {
            return
        }

        let dangerousProperties = ["allowsExpiredCertificates", "allowsExpiredRoots"]
        let name = member.declName.baseName.text
        guard dangerousProperties.contains(name) else { return }

        // Only flag when set to true
        guard boolLiteral.literal.tokenKind == .keyword(.true) else { return }

        let location = node.startLocation(
            converter: converter
        )
        report(Diagnostic(
            severity: .error,
            message: "TLS certificate validation weakened — '\(name)' set to true. [CWE-295]",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "security.tls-disabled",
            suggestedFix: "Do not weaken TLS validation — use proper certificate pinning instead"
        ))
    }

    // MARK: - Helpers

    func isRuleEnabled(_ ruleId: String) -> Bool {
        configuration.enabledRules.isEmpty || configuration.enabledRules.contains(ruleId)
    }

    private func containsInterpolation(_ literal: StringLiteralExprSyntax) -> Bool {
        literal.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
    }

    /// The bracketed CWE a diagnostic for `ruleId` cites, read from the manifest.
    ///
    /// Empty when the manifest does not list the rule: a message with no citation is honest,
    /// and one carrying a number nobody recorded is not.
    static func citation(_ ruleId: String) -> String {
        guard let cwe = SecurityRuleManifest.cwe(for: ruleId) else { return "" }
        return "[\(cwe)]"
    }

    /// Records `diagnostic`, or the acknowledgement that answers it.
    ///
    /// Every security rule reports through here, so every rule is held to one contract. A
    /// `// SECURITY:` marker on the finding's line or the one above is an acknowledgement only
    /// if what follows it passes ``JustificationValidator``; then it is recorded as an
    /// override and the finding is not reported. A marker that fails leaves the finding
    /// standing, at its own severity, with a sentence saying why the marker was not accepted.
    /// Silence and an unexplained exemption were the same thing to every report before this.
    func report(_ diagnostic: Diagnostic) {
        guard let line = diagnostic.lineNumber,
              let ruleId = diagnostic.ruleId,
              let marker = securityMarker(near: line) else {
            diagnostics.append(diagnostic)
            return
        }

        switch justificationValidator.validate(marker.text, keyword: Self.marker) {
        case .valid:
            overrides.append(DiagnosticOverride(
                ruleId: ruleId,
                justification: Self.payload(of: marker.text),
                filePath: fileName,
                lineNumber: line))
        case .tooShort(let wordCount):
            diagnostics.append(Self.rejecting(
                diagnostic, markerLine: marker.line,
                because: "\(wordCount) word\(wordCount == 1 ? "" : "s"), 8 required"))
        case .generic(let phrase):
            diagnostics.append(Self.rejecting(
                diagnostic, markerLine: marker.line,
                because: "'\(phrase)' is a generic phrase, not a reason"))
        case .duplicate:
            // `validate` never answers this; only `validateForDuplicates` does, and a reason
            // that recurs across sibling call sites is legitimate. Reporting is the safe
            // reading if that ever changes.
            diagnostics.append(diagnostic)
        }
    }

    /// The marker every security acknowledgement is written with.
    ///
    /// Only this one. The safety auditor's markers used to be passed in too, so a
    /// `// SAFETY:` written to excuse a force unwrap also excused a hard-coded secret on the
    /// same line.
    static let marker = "// SECURITY:"

    /// The `// SECURITY:` comment on `line` or the line above, if there is one.
    private func securityMarker(near line: Int) -> (text: String, line: Int)? {
        for candidate in [line, line - 1] where sourceLines.indices.contains(candidate - 1) {
            let content = sourceLines[candidate - 1]
            guard let range = content.range(of: Self.marker) else { continue }
            return (String(content[range.lowerBound...]), candidate)
        }
        return nil
    }

    /// What follows the marker.
    private static func payload(of markerText: String) -> String {
        guard let range = markerText.range(of: marker) else { return markerText }
        return markerText[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// `diagnostic`, unchanged but for a sentence saying why its acknowledgement failed.
    private static func rejecting(
        _ diagnostic: Diagnostic,
        markerLine: Int,
        because reason: String
    ) -> Diagnostic {
        Diagnostic(
            severity: diagnostic.severity,
            message: diagnostic.message
                + " (The \(marker) acknowledgement on line \(markerLine) was not accepted: "
                + "\(reason). Say why this is safe here, in a sentence.)",
            filePath: diagnostic.filePath,
            lineNumber: diagnostic.lineNumber,
            columnNumber: diagnostic.columnNumber,
            ruleId: diagnostic.ruleId,
            suggestedFix: diagnostic.suggestedFix,
            origin: diagnostic.origin,
            endLine: diagnostic.endLine)
    }
}

/// Before a position: the text of every `guard` / `if` condition list, and of every call to a
/// configured containment checker.
private final class ConditionCollector: SyntaxVisitor {
    private let limit: AbsolutePosition
    private let checkers: [String]
    private(set) var conditions: [String] = []
    private(set) var checkerCalls: [String] = []

    init(before limit: AbsolutePosition, checkers: [String]) {
        self.limit = limit
        self.checkers = checkers
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ConditionElementListSyntax) -> SyntaxVisitorContinueKind {
        if node.position < limit { conditions.append(node.trimmedDescription) }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if node.position < limit, checkers.contains(node.calledExpression.trimmedDescription) {
            checkerCalls.append(node.trimmedDescription)
        }
        return .visitChildren
    }
}
