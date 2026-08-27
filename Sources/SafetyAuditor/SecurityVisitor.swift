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
/// | `security.weak-crypto` | 327 | CC_MD5, CC_SHA1, Insecure.* hash calls |
/// | `security.insecure-transport` | 319 | http:// URLs (excluding localhost) |
/// | `security.eval-js` | 95 | evaluateJavaScript with non-literal argument |
/// | `security.sql-injection` | 89 | Interpolation in SQL-executing function call |
/// | `security.insecure-keychain` | 311 | Deprecated keychain accessibility constants |
/// | `security.tls-disabled` | 295 | Certificate validation disabled |
/// | `security.path-traversal` | 22 | FileManager with dynamic path |
/// | `security.ssrf` | 918 | URL(string:) with non-literal argument |
final class SecurityVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    let sourceLines: [String]
    let exemptionPatterns: [String]
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

    init(
        fileName: String,
        source: String,
        converter: SourceLocationConverter,
        exemptionPatterns: [String],
        configuration: SecurityAuditorConfig,
        sourceFile: SourceFileSyntax? = nil
    ) {
        self.localStringConstants = sourceFile.map(Self.stringLiteralConstants(in:)) ?? []
        self.fileName = fileName
        self.source = source
        self.converter = converter
        self.sourceLines = source.lines
        self.exemptionPatterns = exemptionPatterns
        self.configuration = configuration
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Variable Declaration Visitor

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard isRuleEnabled("security.hardcoded-secret") else {
            return .visitChildren
        }

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }

            let name = pattern.identifier.text.lowercased()

            // Check if variable name matches secret patterns
            let isSecretName = configuration.secretPatterns.contains { pattern in
                name.contains(pattern.lowercased())
            }
            guard isSecretName else { continue }

            // Check if assigned a string literal
            guard let initializer = binding.initializer,
                  initializer.value.is(StringLiteralExprSyntax.self) else {
                continue
            }

            let location = node.startLocation(
                converter: converter
            )
            if isExempted(line: location.line) {
    
                continue
            }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "Hardcoded secret or credential detected in '\(pattern.identifier.text)'. [CWE-798]",
                filePath: fileName,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: "security.hardcoded-secret",
                suggestedFix: "Load secrets from environment variables, keychain, or a secure configuration provider"
            ))
        }

        return .visitChildren
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
        return .visitChildren
    }

    // MARK: - String Literal Visitor (insecure transport)

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
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
        if isExempted(line: location.line) {

            return .visitChildren
        }

        diagnostics.append(Diagnostic(
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
        return .visitChildren
    }

    // MARK: - Sequence Expression Visitor (TLS disabled via assignment)
    // Note: SwiftSyntax in source-accurate mode produces SequenceExprSyntax
    // for assignments (not InfixOperatorExprSyntax, which requires folding).

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        checkTLSAssignment(node)
        // Order matters and follows source order: the executable is assigned before the
        // arguments in every shape this rule recognises.
        noteExecutableAssignment(node)
        checkShellCommandAssembly(node)
        return .visitChildren
    }

    // MARK: - Rule Implementations

    // MARK: Command Injection (CWE-78)

    /// Shell interpreters, by executable base name.
    ///
    /// The list is the point of the rule: injection needs an interpreter. A `Process` given an
    /// `arguments` array invokes none — each element arrives as one `argv` entry, so a filename
    /// containing `; rm -rf /` is passed as a filename and nothing parses it.
    private static let shellNames: Set<String> = [
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

    /// Records `x.executableURL = URL(fileURLWithPath: "/bin/sh")` and `x.launchPath = "/bin/sh"`.
    ///
    /// Called for every assignment; only shell paths are retained.
    func noteExecutableAssignment(_ node: SequenceExprSyntax) {
        let elements = Array(node.elements)
        guard elements.count >= 3,
              elements[1].is(AssignmentExprSyntax.self),
              let member = elements[0].as(MemberAccessExprSyntax.self),
              let base = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text else { return }
        let property = member.declName.baseName.text
        guard property == "executableURL" || property == "launchPath" else { return }

        guard let path = Self.firstStringLiteral(in: elements[2]) else { return }
        let name = (path as NSString).lastPathComponent
        // `env` defers the choice of interpreter to its first argument, so the decision moves to
        // the argument array; treating it as a shell here is what makes `env sh -c` reachable.
        if Self.shellNames.contains(name) || name == "env" {
            shellVariables.insert(base)
        }
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
            if isExempted(line: location.line) {
                overrides.append(DiagnosticOverride(
                    ruleId: "security.command-injection",
                    justification: sourceLines.indices.contains(location.line - 2)
                        ? sourceLines[location.line - 2].trimmingCharacters(in: .whitespaces)
                        : "acknowledged",
                    filePath: fileName,
                    lineNumber: location.line))
                return
            }

            diagnostics.append(Diagnostic(
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
    private static func firstStringLiteral(in expression: ExprSyntaxProtocol) -> String? {
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

    // MARK: Weak Crypto (CWE-327)

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

    private func emitWeakCryptoDiagnostic(_ node: FunctionCallExprSyntax, algorithm: String) {
        let location = node.startLocation(
            converter: converter
        )
        if isExempted(line: location.line) {

            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Use of weak cryptographic hash '\(algorithm)'. [CWE-327]",
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
        if isExempted(line: location.line) {

            return
        }

        diagnostics.append(Diagnostic(
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
            if isExempted(line: location.line) {
    
                return
            }

            diagnostics.append(Diagnostic(
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
        if isExempted(line: location.line) {

            return
        }

        diagnostics.append(Diagnostic(
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

    private func checkPathTraversal(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.path-traversal") else { return }

        // Check for FileManager.default.<method>(atPath: <non-literal>)
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else {
            return
        }

        let fileManagerMethods = [
            "fileExists", "contentsOfDirectory", "createDirectory",
            "removeItem", "copyItem", "moveItem", "contents",
            "createFile", "attributesOfItem"
        ]

        let methodName = member.declName.baseName.text
        guard fileManagerMethods.contains(methodName) else { return }

        // Check for atPath: parameter with non-literal value
        for arg in node.arguments {
            guard arg.label?.text == "atPath" || arg.label?.text == "path" else {
                continue
            }

            // If the argument is a simple string literal, it's safe
            if let literal = arg.expression.as(StringLiteralExprSyntax.self),
               !containsInterpolation(literal) {
                continue
            }

            let location = node.startLocation(
                converter: converter
            )
            if isExempted(line: location.line) {
    
                return
            }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "FileManager operation with dynamic path — validate and sanitize to prevent path traversal. [CWE-22]",
                filePath: fileName,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: "security.path-traversal",
                suggestedFix: "Use URL.standardized to resolve path traversal sequences and validate against an allowed directory"
            ))
            return // One diagnostic per call site
        }
    }

    // MARK: Insecure Keychain (CWE-311)

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
        if isExempted(line: location.line) {

            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Insecure Keychain accessibility level '\(name)' — allows access when device is locked. [CWE-311]",
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
        if isExempted(line: location.line) {

            return
        }

        diagnostics.append(Diagnostic(
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
        if isExempted(line: location.line) {

            return
        }

        diagnostics.append(Diagnostic(
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

    private func isRuleEnabled(_ ruleId: String) -> Bool {
        configuration.enabledRules.isEmpty || configuration.enabledRules.contains(ruleId)
    }

    private func containsInterpolation(_ literal: StringLiteralExprSyntax) -> Bool {
        literal.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
    }

    private func isExempted(line: Int) -> Bool {
        let linesToCheck = [line - 1, line]
            .filter { $0 >= 1 && $0 <= sourceLines.count }
        for lineNum in linesToCheck {
            let lineContent = sourceLines[lineNum - 1]
            for pattern in exemptionPatterns {
                if lineContent.contains(pattern) {
                    return true
                }
            }
        }
        return false
    }
}
