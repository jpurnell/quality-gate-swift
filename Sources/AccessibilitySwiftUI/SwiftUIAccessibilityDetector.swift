import AccessibilityCore
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Namespaced rule identifiers for the SwiftUI accessibility detector.
enum SwiftUIAccessibilityRule {
    static let fixedFontSize = "a11y.swiftui.fixed-font-size"
    static let missingReduceMotion = "a11y.swiftui.missing-reduce-motion"
    static let missingAccessibilityLabel = "a11y.swiftui.missing-accessibility-label"
}

/// Detects accessibility violations in SwiftUI source.
///
/// Enforces three HIG-grounded rules:
/// - `a11y.swiftui.fixed-font-size`: `.font(.system(size:))` instead of semantic text styles (Dynamic Type).
/// - `a11y.swiftui.missing-reduce-motion`: `withAnimation` / `.animation()` without an `accessibilityReduceMotion` guard.
/// - `a11y.swiftui.missing-accessibility-label`: `Image` without `.accessibilityLabel()` or `.accessibilityHidden(true)`.
public struct SwiftUIAccessibilityDetector: AccessibilityDetector {

    /// This detector audits the SwiftUI frontend.
    public let frontend: Frontend = .swiftUI

    /// Creates a SwiftUI accessibility detector.
    public init() {}

    /// Parse the unit's source and report SwiftUI accessibility violations.
    public func detect(in unit: SourceUnit) -> DetectionResult {
        let tree = Parser.parse(source: unit.source)
        let visitor = SwiftUIAccessibilityVisitor(
            fileName: unit.fileName,
            source: unit.source,
            exemptionPatterns: unit.exemptionPatterns,
            tree: tree
        )
        visitor.walk(tree)
        return DetectionResult(diagnostics: visitor.diagnostics, overrides: visitor.overrides)
    }
}

// MARK: - Syntax Visitor

final class SwiftUIAccessibilityVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    let exemptionPatterns: [String]
    let sourceLines: [String]
    let converter: SourceLocationConverter
    var diagnostics: [Diagnostic] = []
    var overrides: [DiagnosticOverride] = []

    init(fileName: String, source: String, exemptionPatterns: [String], tree: SourceFileSyntax) {
        self.fileName = fileName
        self.source = source
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.components(separatedBy: .newlines)
        self.converter = SourceLocationConverter(fileName: fileName, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Rule: fixed-font-size

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        checkFixedFontSize(node)
        checkWithAnimationMissingReduceMotion(node)
        return .visitChildren
    }

    /// Detects `.font(.system(size: N))` — should use semantic text styles
    /// for Dynamic Type support (Low vision, Motor).
    private func checkFixedFontSize(_ node: FunctionCallExprSyntax) {
        // Match: .system(size: ...)
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
              memberAccess.declName.baseName.text == "system" else {
            return
        }

        let hasSize = node.arguments.contains { arg in
            arg.label?.text == "size"
        }
        guard hasSize else { return }

        let location = node.startLocation(
            converter: converter
        )
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.fixedFontSize) {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Fixed font size detected. Users who need larger text (low vision) or larger tap targets (motor) won't benefit from Dynamic Type. — \(AccessibilityPrinciple.scalableText.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.fixedFontSize,
            suggestedFix: "Use a semantic text style instead: .font(.body), .font(.headline), .font(.caption), etc. These scale automatically with the user's Dynamic Type setting."
        ))
    }

    /// Detects `withAnimation { ... }` without a nearby
    /// `accessibilityReduceMotion` check.
    private func checkWithAnimationMissingReduceMotion(_ node: FunctionCallExprSyntax) {
        guard let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
              ref.baseName.text == "withAnimation" else {
            return
        }

        let location = node.startLocation(
            converter: converter
        )
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.missingReduceMotion) {
            overrides.append(override)
            return
        }

        if hasReduceMotionCheck(for: node) { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "withAnimation used without an accessibilityReduceMotion check. Users with motion sensitivity (low vision, vestibular disorders) or motor difficulties may need reduced or no animation. — \(AccessibilityPrinciple.respectMotionPref.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.missingReduceMotion,
            suggestedFix: "Guard with: @Environment(\\.accessibilityReduceMotion) var reduceMotion — then use withAnimation(reduceMotion ? nil : .default) { ... } or skip the animation entirely."
        ))
    }

    // MARK: - Rule: missing-accessibility-label (via member access modifiers)

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        checkAnimationModifier(node)
        return .visitChildren
    }

    /// Detects `.animation(...)` modifier without nearby reduceMotion check.
    private func checkAnimationModifier(_ node: MemberAccessExprSyntax) {
        guard node.declName.baseName.text == "animation" else { return }

        let location = node.period.startLocation(
            converter: converter
        )
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.missingReduceMotion) {
            overrides.append(override)
            return
        }

        if hasReduceMotionCheck(for: node) { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: ".animation() modifier used without an accessibilityReduceMotion check. Users with motion sensitivity may need reduced or no animation. — \(AccessibilityPrinciple.respectMotionPref.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.missingReduceMotion,
            suggestedFix: "Guard with: @Environment(\\.accessibilityReduceMotion) var reduceMotion — then conditionally apply: .animation(reduceMotion ? nil : .default, value: ...)"
        ))
    }

    // MARK: - Rule: Image without accessibilityLabel

    override func visit(_ node: LabeledExprSyntax) -> SyntaxVisitorContinueKind {
        checkImageWithoutLabel(node)
        return .visitChildren
    }

    /// Detects `Image(systemName:)` or `Image("name")` that isn't followed
    /// by `.accessibilityLabel()` in the same modifier chain.
    private func checkImageWithoutLabel(_ node: LabeledExprSyntax) {
        // We check at the FunctionCallExpr level for Image(...)
        guard let call = node.parent?.parent?.as(FunctionCallExprSyntax.self),
              let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
              ref.baseName.text == "Image" else {
            return
        }

        // Walk up the modifier chain looking for .accessibilityLabel
        if hasModifierInChain(from: call, named: "accessibilityLabel") { return }
        if hasModifierInChain(from: call, named: "accessibilityHidden") { return }

        let location = call.startLocation(
            converter: converter
        )
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.missingAccessibilityLabel) {
            overrides.append(override)
            return
        }

        // Only flag once per Image call (check we're the first argument)
        guard node == call.arguments.first else { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Image without .accessibilityLabel() or .accessibilityHidden(true). VoiceOver users (blind) will hear the raw image name or nothing. Screen reader is the primary UI for blind users. — \(AccessibilityPrinciple.textAlternative.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.missingAccessibilityLabel,
            suggestedFix: "Add .accessibilityLabel(\"description\") for meaningful images, or .accessibilityHidden(true) for purely decorative images."
        ))
    }

    // MARK: - Helpers

    private func hasReduceMotionCheck(for node: some SyntaxProtocol) -> Bool {
        let location = node.startLocation(converter: converter)

        // Fast path: check ±10 line radius
        if hasNearbyReduceMotionCheck(around: location.line) { return true }

        // Scope walk: check each enclosing scope up to the function boundary
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            let isFuncBoundary = parent.is(FunctionDeclSyntax.self) ||
                parent.is(AccessorDeclSyntax.self)
            let isScopeBoundary = isFuncBoundary ||
                parent.is(ClosureExprSyntax.self) ||
                parent.is(AccessorBlockSyntax.self)

            if isScopeBoundary {
                let startLoc = parent.startLocation(converter: converter)
                let endLoc = parent.endLocation(converter: converter)
                if searchLines(from: startLoc.line, to: endLoc.line) {
                    return true
                }
                if isFuncBoundary { return false }
            }
            current = parent
        }

        return false
    }

    private func searchLines(from startLine: Int, to endLine: Int) -> Bool {
        let start = max(0, startLine - 1)
        let end = min(sourceLines.count - 1, endLine - 1)
        guard start <= end else { return false }
        for i in start...end {
            let content = sourceLines[i]
            if content.contains("reduceMotion") || content.contains("accessibilityReduceMotion") {
                return true
            }
        }
        return false
    }

    private func hasNearbyReduceMotionCheck(around line: Int, radius: Int = 10) -> Bool {
        let start = max(0, line - radius - 1)
        let end = min(sourceLines.count - 1, line + radius - 1)
        for i in start...end {
            let content = sourceLines[i]
            if content.contains("reduceMotion") || content.contains("accessibilityReduceMotion") {
                return true
            }
        }
        return false
    }

    private func hasModifierInChain(from node: some SyntaxProtocol, named modifier: String) -> Bool {
        // Walk up through function call expressions looking for .modifier(...)
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if let call = parent.as(FunctionCallExprSyntax.self),
               let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == modifier {
                return true
            }
            current = parent
        }
        return false
    }

    private func overrideIfExempted(line: Int, ruleId: String) -> DiagnosticOverride? {
        let linesToCheck = [line - 1, line]
            .filter { $0 >= 1 && $0 <= sourceLines.count }
        for lineNum in linesToCheck {
            let lineContent = sourceLines[lineNum - 1]
            for pattern in exemptionPatterns {
                if lineContent.contains(pattern) {
                    return DiagnosticOverride(
                        ruleId: ruleId,
                        justification: lineContent.trimmingCharacters(in: .whitespaces),
                        filePath: fileName,
                        lineNumber: line
                    )
                }
            }
        }
        return nil
    }
}
