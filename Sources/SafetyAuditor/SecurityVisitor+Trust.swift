import Foundation
import QualityGateCore
import SwiftSyntax

/// The rules about what a client agrees to trust.
///
/// `security.tls-disabled` used to match three identifiers — `disableEvaluation`,
/// `allowsExpiredCertificates`, `allowsExpiredRoots` — and none of them is URLSession,
/// Network.framework, SwiftNIO or AsyncHTTPClient API. The one way validation was actually
/// switched off in owned code, NIOSSL's `certificateVerification = .none` (three transports in
/// SwiftMCPClient), the rule had never heard of. This file widens that rule and adds the three
/// beside it:
///
/// | Rule | CWE | Severity | Shape |
/// |------|-----|----------|-------|
/// | `security.tls-disabled` | 295 | error | `.none` for a client's `certificateVerification`, `SecTrustSetExceptions`, `DisabledTrustEvaluator` |
/// | `security.tls-no-hostname` | 297 | error | `.noHostnameVerification` on a client, `validateHost: false`, `SecPolicyCreateSSL(true, nil)`, a basic X.509 policy on a trust |
///
/// A *server* configuration is exempt from both mode findings: there `certificateVerification`
/// governs client certificates, `.none` is NIOSSL's default for a server that is not doing mutual
/// TLS, and `.noHostnameVerification` is what its own `makeServerConfigurationWithMTLS` sets.
/// | `security.trust-handler-accepts-all` | 295 | error | a server-trust challenge answered with `URLCredential(trust:)` and no evaluation whose result is used |
/// | `security.trust-anchors-widened` | 295 | warning | `SecTrustSetAnchorCertificatesOnly(_, false)` |
///
/// Every finding goes through ``SecurityVisitor/report(_:)``, so a `// SECURITY:` reason is
/// validated and recorded exactly as it is for every other security rule.
///
/// See `quality-gate-swift-project/plans/proposals/TrustHasMoreThanThreeOffSwitches.md`.
extension SecurityVisitor {

    // MARK: - Positions where a certificate-verification mode is chosen

    /// `x.certificateVerification = .none`, including `.none(…)` and either arm of a ternary.
    ///
    /// A guard around the assignment is not consulted: a switch that turns validation off is the
    /// defect whether or not it is currently thrown.
    func checkCertificateVerificationAssignment(_ node: SequenceExprSyntax) {
        let elements = Array(node.elements)
        guard elements.count >= 3,
              elements[1].is(AssignmentExprSyntax.self),
              let member = elements[0].as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "certificateVerification" else { return }

        let onServer = member.base
            .flatMap { $0.as(DeclReferenceExprSyntax.self)?.baseName.text }
            .flatMap { Self.bindingInitialiser(named: $0, before: node) }
            .map(Self.isServerConfiguration) ?? false
        reportVerificationModes(in: Array(elements.dropFirst(2)), at: Syntax(node), onServer: onServer)
    }

    /// `certificateVerification: .none` as an argument — NIOSSL's `forClient`, AsyncHTTPClient's
    /// `HTTPClient.Configuration(certificateVerification:)`, and anything else so labelled.
    func checkCertificateVerificationArguments(_ node: FunctionCallExprSyntax) {
        for argument in node.arguments where argument.label?.text == "certificateVerification" {
            let onServer = Self.isServerConfiguration(node.calledExpression)
            reportVerificationModes(in: [argument.expression], at: Syntax(argument), onServer: onServer)
        }
    }

    /// `let mode: CertificateVerification = .none` — the ternary-through-a-variable shape the
    /// proposal warned about, caught where the mode is chosen rather than where it is used.
    func checkTypedCertificateVerification(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            guard let type = binding.typeAnnotation?.type.trimmedDescription,
                  type.hasSuffix("CertificateVerification"),
                  let value = binding.initializer?.value else { continue }
            reportVerificationModes(in: [value], at: Syntax(binding), onServer: false)
        }
    }

    /// Reports each distinct dangerous mode among `expressions`, once.
    private func reportVerificationModes(in expressions: [ExprSyntax], at site: Syntax, onServer: Bool) {
        var seen: Set<String> = []
        for mode in expressions.flatMap(Self.verificationModes(in:)) where seen.insert(mode).inserted {
            switch mode {
            case "none" where !onServer:
                reportTrust(
                    "security.tls-disabled", at: site,
                    message: "Certificate validation switched off: certificateVerification is .none, which "
                        + "accepts any certificate from anyone able to answer the connection.",
                    fix: "Keep .fullVerification. To trust one self-signed certificate, add it to "
                        + "additionalTrustRoots rather than verifying nothing.")
            case "noHostnameVerification" where !onServer:
                reportTrust(
                    "security.tls-no-hostname", at: site,
                    message: "Certificate checked against the trust store but not against the host: "
                        + ".noHostnameVerification accepts any valid certificate for any name.",
                    fix: "Use .fullVerification on a client. .noHostnameVerification is for a server "
                        + "checking client certificates, which has no hostname to compare.")
            default:
                break
            }
        }
    }

    /// The `CertificateVerification` cases `expression` can evaluate to that this file reports.
    ///
    /// Looks through a call (`.none(options)`) and both arms of an unfolded ternary. A base other
    /// than a `CertificateVerification` type is not accepted, so `Optional.none` is not one.
    static func verificationModes(in expression: ExprSyntax) -> [String] {
        if let sequence = expression.as(SequenceExprSyntax.self) {
            var modes: [String] = []
            for element in sequence.elements {
                if let ternary = element.as(UnresolvedTernaryExprSyntax.self) {
                    modes += verificationModes(in: ternary.thenExpression)
                } else if !element.is(UnresolvedTernaryExprSyntax.self) {
                    modes += verificationModes(in: element)
                }
            }
            return modes
        }
        if let ternary = expression.as(UnresolvedTernaryExprSyntax.self) {
            return verificationModes(in: ternary.thenExpression)
        }
        if let ternary = expression.as(TernaryExprSyntax.self) {
            return verificationModes(in: ternary.thenExpression) + verificationModes(in: ternary.elseExpression)
        }
        var callee = expression
        if let call = expression.as(FunctionCallExprSyntax.self) { callee = call.calledExpression }
        guard let member = callee.as(MemberAccessExprSyntax.self) else { return [] }
        let name = member.declName.baseName.text
        guard name == "none" || name == "noHostnameVerification" else { return [] }
        if let base = member.base, !base.trimmedDescription.hasSuffix("CertificateVerification") {
            return []
        }
        return [name]
    }

    /// Whether an expression builds a *server* TLS configuration.
    private static func isServerConfiguration(_ expression: ExprSyntax) -> Bool {
        let text = expression.trimmedDescription
        return text.contains("makeServerConfiguration") || text.contains("forServer")
    }

    // MARK: - Security framework and Alamofire calls

    /// `SecTrustSetExceptions`, `SecTrustSetAnchorCertificatesOnly(_, false)`,
    /// `SecPolicyCreateSSL(true, nil)`, a basic X.509 policy given to `SecTrustSetPolicies`, and
    /// Alamofire evaluators told not to validate the host.
    func checkTrustCalls(_ node: FunctionCallExprSyntax) {
        let arguments = Array(node.arguments)
        let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text

        switch callee {
        case "SecTrustSetExceptions":
            reportTrust(
                "security.tls-disabled", at: Syntax(node),
                message: "SecTrustSetExceptions makes a trust object that failed evaluation pass it.",
                fix: "Evaluate the trust and act on the result. Trust-on-first-use, if that is the "
                    + "design, is acknowledged with // SECURITY: <how the stored exception is bound>.")
        case "SecTrustSetAnchorCertificatesOnly":
            guard arguments.count == 2, Self.isBoolLiteral(arguments[1].expression, false) else { return }
            reportTrust(
                "security.trust-anchors-widened", at: Syntax(node),
                severity: .warning,
                message: "SecTrustSetAnchorCertificatesOnly(_, false) re-enables the built-in anchors: a "
                    + "trust object pinned to a private CA goes back to accepting any public CA too.",
                fix: "Pass true if pinning was the point; otherwise say so with // SECURITY: <reason>.")
        case "SecPolicyCreateSSL":
            guard arguments.count == 2,
                  Self.isBoolLiteral(arguments[0].expression, true),
                  arguments[1].expression.is(NilLiteralExprSyntax.self) else { return }
            reportTrust(
                "security.tls-no-hostname", at: Syntax(node),
                message: "SecPolicyCreateSSL(true, nil) is a server policy with no hostname, so the "
                    + "certificate is never matched against the host it came from.",
                fix: "Pass the host: SecPolicyCreateSSL(true, host as CFString).")
        case "SecTrustSetPolicies":
            guard arguments.count == 2, isBasicX509Policy(arguments[1].expression, at: node) else { return }
            reportTrust(
                "security.tls-no-hostname", at: Syntax(node),
                message: "A basic X.509 policy set on a trust object checks the chain and no hostname.",
                fix: "For a TLS peer use SecPolicyCreateSSL(true, host as CFString).")
        default:
            checkHostValidationDisabled(node, arguments: arguments)
        }
    }

    /// Alamofire's `validateHost: false`, on an evaluator initialiser or one of its leading-dot
    /// factories.
    ///
    /// Not `performDefaultValidation: false`, which the proposal listed. Alamofire documents
    /// `validateHost` as validating the host "even if `performDefaultValidation` is `false`", and
    /// its evaluators do exactly that; matched against Alamofire's own tests the label alone was
    /// 27 findings, none of them a hostname left unchecked.
    private func checkHostValidationDisabled(_ node: FunctionCallExprSyntax, arguments: [LabeledExprSyntax]) {
        let callee = node.calledExpression
        let isEvaluator = callee.trimmedDescription.hasSuffix("TrustEvaluator")
            || callee.as(MemberAccessExprSyntax.self)?.base == nil && callee.is(MemberAccessExprSyntax.self)
        guard isEvaluator,
              arguments.contains(where: {
                  $0.label?.text == "validateHost" && Self.isBoolLiteral($0.expression, false)
              }) else { return }
        reportTrust(
            "security.tls-no-hostname", at: Syntax(node),
            message: "Server trust evaluator constructed with validateHost: false, so the certificate "
                + "is not checked against the host.",
            fix: "Leave validateHost at its default of true.")
    }

    /// Whether `expression` is, or names a binding initialised to, `SecPolicyCreateBasicX509()`.
    private func isBasicX509Policy(_ expression: ExprSyntax, at node: some SyntaxProtocol) -> Bool {
        if let reference = expression.as(DeclReferenceExprSyntax.self),
           let value = Self.bindingInitialiser(named: reference.baseName.text, before: node) {
            return value.trimmedDescription.contains("SecPolicyCreateBasicX509()")
        }
        return expression.trimmedDescription.contains("SecPolicyCreateBasicX509()")
    }

    /// Any reference to Alamofire's `DisabledTrustEvaluator`, or its deprecated alias.
    ///
    /// Alamofire's own doc comment: *"THIS EVALUATOR SHOULD NEVER BE USED IN PRODUCTION!"*
    func checkDisabledEvaluator(_ node: DeclReferenceExprSyntax) {
        let name = node.baseName.text
        guard name == "DisabledTrustEvaluator" || name == "DisabledEvaluator" else { return }
        reportTrust(
            "security.tls-disabled", at: Syntax(node),
            message: "\(name) performs no server trust evaluation at all.",
            fix: "Use DefaultTrustEvaluator, or a pinning evaluator with its defaults.")
    }

    // MARK: - Trust-challenge handlers

    /// Evaluation calls whose result decides a trust question.
    static let evaluationFunctions: Set<String> = [
        "SecTrustEvaluateWithError", "SecTrustEvaluateAsyncWithError",
        "SecTrustEvaluate", "SecTrustGetTrustResult",
    ]

    /// A delegate method answering a server-trust challenge with `URLCredential(trust:)` and
    /// `.useCredential`, having used the result of no evaluation.
    ///
    /// A handler is `urlSession(…)` or `webView(…)` with a `URLAuthenticationChallenge`
    /// parameter — the session, task and web-view forms, completion-handler or `async`. Not
    /// checked: whether the evaluation *dominates* the credential. A result read only by a log
    /// statement passes; see the proposal's §6.
    func checkTrustHandler(_ node: FunctionDeclSyntax) {
        let name = node.name.text
        guard name == "urlSession" || name == "webView",
              let body = node.body,
              node.signature.parameterClause.parameters.contains(where: {
                  $0.type.trimmedDescription.contains("URLAuthenticationChallenge")
              }) else { return }

        let scan = TrustBodyScan()
        scan.walk(body)
        guard scan.usesCredentialDisposition,
              let credential = scan.trustCredentials.first,
              !scan.evaluations.contains(where: Self.isResultUsed) else { return }

        reportTrust(
            "security.trust-handler-accepts-all", at: Syntax(credential),
            message: "\(name)(…) answers a server-trust challenge with .useCredential and "
                + "URLCredential(trust:) without using the result of any trust evaluation, so every "
                + "certificate is accepted.",
            fix: "Evaluate first — guard SecTrustEvaluateWithError(trust, &error) else { cancel } — or "
                + "answer .performDefaultHandling and let the system validate.")
    }

    /// `sec_protocol_options_set_verify_block` given a closure whose every completion is `true`
    /// and which evaluates nothing.
    func checkVerifyBlock(_ node: FunctionCallExprSyntax) {
        guard node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
                == "sec_protocol_options_set_verify_block" else { return }
        let closures = node.arguments.compactMap { $0.expression.as(ClosureExprSyntax.self) }
            + [node.trailingClosure].compactMap { $0 }
        guard let closure = closures.first,
              let completion = Self.thirdParameterName(of: closure) else { return }

        let scan = TrustBodyScan(completionName: completion)
        scan.walk(closure.statements)
        guard !scan.completions.isEmpty,
              scan.completions.allSatisfy({ call in
                  call.arguments.count == 1
                      && call.arguments.first.map { Self.isBoolLiteral($0.expression, true) } == true
              }),
              scan.evaluations.isEmpty else { return }

        reportTrust(
            "security.trust-handler-accepts-all", at: Syntax(node),
            message: "The verify block passes true to its completion without evaluating the trust, so "
                + "every certificate is accepted.",
            fix: "Complete with the evaluation: complete(SecTrustEvaluateWithError(trust, nil)).")
    }

    /// The name a closure gives its third parameter, `$2` when it uses shorthand, `nil` for `_`.
    private static func thirdParameterName(of closure: ClosureExprSyntax) -> String? {
        guard let clause = closure.signature?.parameterClause else { return "$2" }
        switch clause {
        case .simpleInput(let list):
            let names = list.map(\.name.text)
            guard names.count == 3, names[2] != "_" else { return nil }
            return names[2]
        case .parameterClause(let parameters):
            let names = parameters.parameters.map { ($0.secondName ?? $0.firstName).text }
            guard names.count == 3, names[2] != "_" else { return nil }
            return names[2]
        }
    }

    /// Whether the value an evaluation produces reaches anything.
    ///
    /// Discarded: `_ = …`, `try? …` as a statement, and a bare `SecTrustEvaluateWithError(…)` or
    /// non-throwing `evaluate(…)` statement. Kept: everything else, including a bare `try
    /// x.evaluate(…)` (the throw is the answer) and the inout and callback forms, whose result
    /// does not arrive as the return value.
    static func isResultUsed(_ call: FunctionCallExprSyntax) -> Bool {
        var top = Syntax(call)
        var tryKinds: [TokenKind?] = []
        while let parent = top.parent, parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) {
            if let tryExpr = parent.as(TryExprSyntax.self) {
                tryKinds.append(tryExpr.questionOrExclamationMark?.tokenKind)
            }
            top = parent
        }
        if let sequence = top.parent?.as(ExprListSyntax.self)?.parent?.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            return !(elements.count == 3 && elements[0].trimmedDescription == "_"
                     && elements[1].is(AssignmentExprSyntax.self))
        }
        guard top.parent?.is(CodeBlockItemSyntax.self) == true else { return true }
        if tryKinds.contains(.postfixQuestionMark) { return false }
        if tryKinds.contains(where: { $0 == nil }) { return true }
        let returnsVerdict = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
            == "SecTrustEvaluateWithError" || call.calledExpression.is(MemberAccessExprSyntax.self)
        return !returnsVerdict
    }

    // MARK: - Shared

    /// Records a trust finding at `site` through ``report(_:)``, if `ruleId` is enabled.
    private func reportTrust(
        _ ruleId: String,
        at site: Syntax,
        severity: Diagnostic.Severity = .error,
        message: String,
        fix: String
    ) {
        guard isRuleEnabled(ruleId) else { return }
        let location = site.startLocation(converter: converter)
        report(Diagnostic(
            severity: severity,
            message: message + " " + Self.citation(ruleId),
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: ruleId,
            suggestedFix: fix
        ))
    }

    private static func isBoolLiteral(_ expression: ExprSyntax, _ value: Bool) -> Bool {
        expression.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(value ? .true : .false)
    }

    /// The initialiser of the last `let` or `var` binding `name` before `node`, searching the
    /// enclosing function, closure or accessor body — or the file, at top level.
    static func bindingInitialiser(named name: String, before node: some SyntaxProtocol) -> ExprSyntax? {
        var scope: Syntax = node.root
        var current = node.parent
        while let candidate = current {
            if candidate.is(CodeBlockSyntax.self) || candidate.is(ClosureExprSyntax.self) {
                scope = candidate
                break
            }
            current = candidate.parent
        }
        var found: ExprSyntax?
        for token in scope.tokens(viewMode: .sourceAccurate) where token.position < node.position {
            guard token.text == name,
                  let pattern = token.parent?.as(IdentifierPatternSyntax.self),
                  let binding = pattern.parent?.as(PatternBindingSyntax.self),
                  let value = binding.initializer?.value else { continue }
            found = value
        }
        return found
    }
}

/// What a handler body or verify block does with trust: the credentials it builds, the
/// evaluations it calls, and (for a verify block) each call of its completion.
private final class TrustBodyScan: SyntaxVisitor {
    private let completionName: String?
    private(set) var usesCredentialDisposition = false
    private(set) var trustCredentials: [FunctionCallExprSyntax] = []
    private(set) var evaluations: [FunctionCallExprSyntax] = []
    private(set) var completions: [FunctionCallExprSyntax] = []

    init(completionName: String? = nil) {
        self.completionName = completionName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "useCredential" { usesCredentialDisposition = true }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = node.calledExpression
        if callee.trimmedDescription == "URLCredential", node.arguments.first?.label?.text == "trust" {
            trustCredentials.append(node)
        }
        if let name = callee.as(DeclReferenceExprSyntax.self)?.baseName.text {
            if SecurityVisitor.evaluationFunctions.contains(name) {
                evaluations.append(node)
            }
            if name == completionName { completions.append(node) }
        }
        // `evaluator.evaluate(trust, forHost:)`, `trust.evaluate()`: a method named evaluate on a
        // receiver named for trust or for an evaluator.
        if let member = callee.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "evaluate",
           let base = member.base?.trimmedDescription.lowercased(),
           base.contains("trust") || base.contains("evaluator") {
            evaluations.append(node)
        }
        return .visitChildren
    }
}
