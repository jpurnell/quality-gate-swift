import Foundation
import QualityGateCore
import QualityGateTypes
import SwiftSyntax

final class ContextVisitor: SyntaxVisitor {
    /// Built once per file by the caller — see ConverterConstructionIsAClassDefect.md.
    let converter: SourceLocationConverter
    let fileName: String
    let source: String
    let sourceLines: [String]
    var diagnostics: [Diagnostic] = []
    /// Findings an annotation comment answered in place of a guard.
    var overrides: [DiagnosticOverride] = []

    private var functionBodyStack: [FunctionScope] = []

    private struct FunctionScope {
        let bodyText: String
    }

    private static let sensitiveTypes: Set<String> = [
        "CLLocationManager", "CNContactStore", "AVCaptureSession",
        "HKHealthStore", "EKEventStore", "PHPhotoLibrary"
    ]

    private static let consentGuardKeywords: [String] = [
        "consent", "Consent", "permission", "Permission",
        "authorization", "Authorization", "hasLocation",
        "isAuthorized", "CONSENT:"
    ]

    private static let analyticsGuardKeywords: [String] = [
        "isTrackingAllowed", "trackingEnabled", "analyticsEnabled",
        "isOptedIn", "optOut", "ANALYTICS:"
    ]

    init(fileName: String, source: String, converter: SourceLocationConverter) {
        self.converter = converter
        self.fileName = fileName
        self.source = source
        self.sourceLines = source.lines
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Function Scope Tracking

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            functionBodyStack.append(FunctionScope(bodyText: body.description))
        }
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        guard let body = node.body else { return }
        let bodyText = body.description

        checkAutomatedDecisionInBody(bodyText, node: Syntax(body))

        _ = functionBodyStack.popLast()
    }

    // MARK: - Function Call Detection

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            if Self.sensitiveTypes.contains(name) {
                checkMissingConsentGuard(for: node)
            }
        }

        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            if let base = member.base?.as(DeclReferenceExprSyntax.self) {
                if Self.sensitiveTypes.contains(base.baseName.text) {
                    checkMissingConsentGuard(for: node)
                }
                if base.baseName.text == "Analytics"
                    && member.declName.baseName.text == "track" {
                    checkUnguardedAnalytics(for: node)
                }
            }
        }

        return .visitChildren
    }

    // MARK: - Assignment Detection (Surveillance)

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        guard elements.count == 3 else { return .visitChildren }

        guard let member = elements[0].as(MemberAccessExprSyntax.self),
              elements[1].is(AssignmentExprSyntax.self),
              let boolLiteral = elements[2].as(BooleanLiteralExprSyntax.self) else {
            return .visitChildren
        }

        if member.declName.baseName.text == "allowsBackgroundLocationUpdates"
            && boolLiteral.literal.tokenKind == .keyword(.true) {
            checkSurveillancePattern(for: node)
        }

        return .visitChildren
    }

    // MARK: - Rule: context.missing-consent-guard

    private func checkMissingConsentGuard(for node: some SyntaxProtocol) {
        if let bodyText = currentFunctionBody(), hasConsentGuard(in: bodyText) {
            // The annotation is recorded only when it is the reason the rule is quiet: a
            // function that also has a real permission check was never going to be reported.
            if !hasConsentGuard(in: Self.blanking("CONSENT:", in: bodyText)) {
                recordAnnotation("CONSENT:", in: bodyText, node: node, ruleId: "context.missing-consent-guard")
            }
            return
        }

        let location = node.startLocation(
            converter: converter
        )

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Sensitive API accessed without consent guard",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "context.missing-consent-guard",
            suggestedFix: "Add a consent or permission check before accessing sensitive APIs, or add a // CONSENT: annotation with justification"
        ))
    }

    private func hasConsentGuard(in bodyText: String) -> Bool {
        if bodyText.contains("CONSENT:") {
            return true
        }

        let lines = bodyText.lines
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isGuardOrIf = trimmed.hasPrefix("guard ") || trimmed.hasPrefix("if ")
            if isGuardOrIf {
                for keyword in Self.consentGuardKeywords {
                    if trimmed.contains(keyword) {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Rule: context.unguarded-analytics

    private func checkUnguardedAnalytics(for node: some SyntaxProtocol) {
        if let bodyText = currentFunctionBody(), hasAnalyticsGuard(in: bodyText) {
            if !hasAnalyticsGuard(in: Self.blanking("ANALYTICS:", in: bodyText)) {
                recordAnnotation("ANALYTICS:", in: bodyText, node: node, ruleId: "context.unguarded-analytics")
            }
            return
        }

        let location = node.startLocation(
            converter: converter
        )

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Analytics tracking without opt-out check",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "context.unguarded-analytics",
            suggestedFix: "Add an opt-out guard before analytics calls, or add a // ANALYTICS: annotation with justification"
        ))
    }

    private func hasAnalyticsGuard(in bodyText: String) -> Bool {
        for keyword in Self.analyticsGuardKeywords {
            if bodyText.contains(keyword) {
                return true
            }
        }
        return false
    }

    // MARK: - Rule: context.automated-decision-without-review

    private func checkAutomatedDecisionInBody(_ bodyText: String, node: some SyntaxProtocol) {
        let hasPrediction = bodyText.contains("predict")
        let hasDenial = bodyText.contains("deny") || bodyText.contains("block")
            || bodyText.contains("suspend")

        guard hasPrediction && hasDenial else { return }

        if bodyText.contains("REVIEWED:") {
            recordAnnotation("REVIEWED:", in: bodyText, node: node, ruleId: "context.automated-decision-without-review")
            return
        }

        let location = node.startLocation(
            converter: converter
        )

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Automated user-affecting decision without human review step",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "context.automated-decision-without-review",
            suggestedFix: "Add a human review step, or add a // REVIEWED: annotation with justification"
        ))
    }

    // MARK: - Rule: context.surveillance-pattern

    private func checkSurveillancePattern(for node: some SyntaxProtocol) {
        if let bodyText = currentFunctionBody(), bodyText.contains("DISCLOSURE:") {
            recordAnnotation("DISCLOSURE:", in: bodyText, node: node, ruleId: "context.surveillance-pattern")
            return
        }

        let location = node.startLocation(
            converter: converter
        )

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Background location tracking without disclosure",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: "context.surveillance-pattern",
            suggestedFix: "Add a // DISCLOSURE: annotation explaining the purpose per your privacy policy"
        ))
    }

    // MARK: - Helpers

    private func currentFunctionBody() -> String? {
        functionBodyStack.last?.bodyText
    }

    /// `bodyText` with an annotation keyword overwritten, to ask what the rule says without it.
    private static func blanking(_ annotation: String, in bodyText: String) -> String {
        bodyText.replacingOccurrences(
            of: annotation, with: String(repeating: "_", count: annotation.count))
    }

    /// Records that an annotation comment, rather than code, is why a rule did not report.
    ///
    /// The four annotations — `CONSENT:`, `ANALYTICS:`, `REVIEWED:`, `DISCLOSURE:` — are
    /// matched anywhere in the enclosing function's text, and until now left no trace: the
    /// rule simply did not fire. Each takes a justification that nothing checks, so the
    /// reason is judged like any other unvalidated form.
    private func recordAnnotation(
        _ annotation: String, in bodyText: String, node: some SyntaxProtocol, ruleId: String
    ) {
        let location = node.startLocation(converter: converter)
        let comment = bodyText.lines.first { $0.contains(annotation) } ?? annotation
        overrides.append(.inlineMarker(
            form: "// \(annotation)", ruleId: ruleId, filePath: fileName, findingLine: location.line,
            markerLine: nil, comment: InlineMarker.reason(in: comment, after: annotation),
            reportOnly: true))
    }
}
