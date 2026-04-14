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
    var diagnostics: [Diagnostic] = []

    init(
        fileName: String,
        source: String,
        exemptionPatterns: [String],
        configuration: SecurityAuditorConfig
    ) {
        self.fileName = fileName
        self.source = source
        self.sourceLines = source.components(separatedBy: .newlines)
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
                converter: SourceLocationConverter(fileName: fileName, tree: node.root)
            )
            guard !isExempted(line: location.line) else { continue }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "Hardcoded secret or credential detected in '\(pattern.identifier.text)'. [CWE-798]",
                file: fileName,
                line: location.line,
                column: location.column,
                ruleId: "security.hardcoded-secret",
                suggestedFix: "Load secrets from environment variables, keychain, or a secure configuration provider"
            ))
        }

        return .visitChildren
    }

    // MARK: - Function Call Visitor

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        checkCommandInjection(node)
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
        guard text.hasPrefix("http://") else { return .visitChildren }

        // Extract host from URL
        let afterScheme = text.dropFirst("http://".count)
        let host = String(afterScheme.prefix(while: { $0 != "/" && $0 != ":" && $0 != "?" }))

        // Allow configured safe hosts
        guard !configuration.allowedHTTPHosts.contains(host) else {
            return .visitChildren
        }

        let location = node.startLocation(
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return .visitChildren }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Insecure HTTP URL detected — use HTTPS instead. [CWE-319]",
            file: fileName,
            line: location.line,
            column: location.column,
            ruleId: "security.insecure-transport",
            suggestedFix: "Replace http:// with https://"
        ))

        return .visitChildren
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
        return .visitChildren
    }

    // MARK: - Rule Implementations

    // MARK: Command Injection (CWE-78)

    private func checkCommandInjection(_ node: FunctionCallExprSyntax) {
        guard isRuleEnabled("security.command-injection") else { return }

        // Detect Process() or NSTask() instantiation
        let callee: String
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            callee = ref.baseName.text
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            callee = member.declName.baseName.text
        } else {
            return
        }

        guard callee == "Process" || callee == "NSTask" else { return }

        let location = node.startLocation(
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: "Process/NSTask instantiation detected — validate and sanitize dynamic arguments. [CWE-78]",
            file: fileName,
            line: location.line,
            column: location.column,
            ruleId: "security.command-injection",
            suggestedFix: "Use a hardcoded executable path and validate all arguments"
        ))
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
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Use of weak cryptographic hash '\(algorithm)'. [CWE-327]",
            file: fileName,
            line: location.line,
            column: location.column,
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
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: "evaluateJavaScript called with dynamic input — enables code injection. [CWE-95]",
            file: fileName,
            line: location.line,
            column: location.column,
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
                converter: SourceLocationConverter(fileName: fileName, tree: node.root)
            )
            guard !isExempted(line: location.line) else { return }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "SQL query with string interpolation — use parameterized queries. [CWE-89]",
                file: fileName,
                line: location.line,
                column: location.column,
                ruleId: "security.sql-injection",
                suggestedFix: "Use parameterized queries with ? placeholders instead of string interpolation"
            ))
            return // One diagnostic per call site
        }
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

        let location = node.startLocation(
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "URL constructed from dynamic input — potential SSRF. [CWE-918]",
            file: fileName,
            line: location.line,
            column: location.column,
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
                converter: SourceLocationConverter(fileName: fileName, tree: node.root)
            )
            guard !isExempted(line: location.line) else { return }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "FileManager operation with dynamic path — validate and sanitize to prevent path traversal. [CWE-22]",
                file: fileName,
                line: location.line,
                column: location.column,
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
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Insecure Keychain accessibility level '\(name)' — allows access when device is locked. [CWE-311]",
            file: fileName,
            line: location.line,
            column: location.column,
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
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: "TLS certificate validation disabled via '\(name)'. [CWE-295]",
            file: fileName,
            line: location.line,
            column: location.column,
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
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: "TLS certificate validation weakened — '\(name)' set to true. [CWE-295]",
            file: fileName,
            line: location.line,
            column: location.column,
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
