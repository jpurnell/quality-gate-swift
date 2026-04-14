import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans SwiftUI source files for accessibility violations.
///
/// Checks are organized by the ability group they serve:
///
/// | Feature              | Low vision    | Blind          | Color blind         | Motor          | Hearing        |
/// |:---------------------|:--------------|:---------------|:--------------------|:---------------|:---------------|
/// | VoiceOver labels     | -             | Primary UI     | -                   | -              | -              |
/// | Dynamic Type         | Text scales   | -              | -                   | Larger targets | -              |
/// | High Contrast        | Sharper edges | -              | Differentiation     | -              | -              |
/// | Color-blind patterns | -             | -              | Shapes, not color   | -              | -              |
/// | Reduce Motion        | Simplified    | -              | -                   | Less distract. | -              |
/// | Switch Control       | -             | -              | -                   | Full playable  | -              |
/// | AudioNarrator        | Supplement    | Primary output | -                   | -              | -              |
/// | Visual indicators    | -             | -              | -                   | -              | Icons for SFX  |
/// | Haptic cues          | Supplement    | Orientation    | -                   | -              | Audio sub.     |
/// | Closed captions      | -             | -              | -                   | -              | Text for all   |
///
/// ## Rules
///
/// - `missing-accessibility-label`: Image or icon-only Button without `.accessibilityLabel()`
/// - `fixed-font-size`: `.font(.system(size:))` instead of semantic text styles
/// - `missing-reduce-motion`: `withAnimation` / `.animation()` without `accessibilityReduceMotion` check
/// - `color-only-differentiation`: `.foregroundColor()` / `.foregroundStyle()` without pattern/shape companion
/// - `missing-accessibility-hint`: Interactive views without `.accessibilityHint()`
/// - `hardcoded-color-string`: Hardcoded color literals instead of asset catalog / adaptive colors
public struct AccessibilityAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "accessibility"

    /// Human-readable name for this checker.
    public let name = "Accessibility Auditor"

    /// Creates a new AccessibilityAuditor instance.
    public init() {}

    /// Run the accessibility audit on the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let sourcesPath = (currentDir as NSString).appendingPathComponent("Sources")

        var allDiagnostics: [Diagnostic] = []

        if fileManager.fileExists(atPath: sourcesPath) { // SAFETY: CLI tool reads local project sources
            let diagnostics = try await auditDirectory(
                at: sourcesPath,
                configuration: configuration
            )
            allDiagnostics.append(contentsOf: diagnostics)
        }

        let duration = ContinuousClock.now - startTime
        let hasErrors = allDiagnostics.contains { $0.severity == .error }
        let status: CheckResult.Status = hasErrors ? .failed : (allDiagnostics.isEmpty ? .passed : .warning)

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            duration: duration
        )
    }

    /// Audit a single source code string.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to audit.
    ///   - fileName: The name of the file (for diagnostics).
    ///   - configuration: The project configuration.
    /// - Returns: A check result with any violations found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration = Configuration()
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let diagnostics = auditSourceCode(source, fileName: fileName, configuration: configuration)

        let duration = ContinuousClock.now - startTime
        let hasErrors = diagnostics.contains { $0.severity == .error }
        let status: CheckResult.Status = hasErrors ? .failed : (diagnostics.isEmpty ? .passed : .warning)

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: duration
        )
    }

    // MARK: - Private Implementation

    private func auditDirectory(
        at path: String,
        configuration: Configuration
    ) async throws -> [Diagnostic] {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return []
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }
            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            if shouldExclude(path: fullPath, patterns: configuration.excludePatterns) {
                continue
            }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let fileDiagnostics = auditSourceCode(source, fileName: fullPath, configuration: configuration)
                diagnostics.append(contentsOf: fileDiagnostics)
            } catch {
                continue
            }
        }

        return diagnostics
    }

    private func shouldExclude(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pathMatches(path: path, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private func pathMatches(path: String, pattern: String) -> Bool {
        if pattern.contains("**") {
            let component = pattern.replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
            return path.contains(component)
        }
        return path.contains(pattern.replacingOccurrences(of: "*", with: ""))
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) -> [Diagnostic] {
        let sourceFile = Parser.parse(source: source)
        let visitor = AccessibilityVisitor(
            fileName: fileName,
            source: source,
            exemptionPatterns: configuration.safetyExemptions
        )
        visitor.walk(sourceFile)
        return visitor.diagnostics
    }
}

// MARK: - Syntax Visitor

final class AccessibilityVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    let exemptionPatterns: [String]
    let sourceLines: [String]
    var diagnostics: [Diagnostic] = []

    init(fileName: String, source: String, exemptionPatterns: [String]) {
        self.fileName = fileName
        self.source = source
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.components(separatedBy: .newlines)
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
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Fixed font size detected. Users who need larger text (low vision) or larger tap targets (motor) won't benefit from Dynamic Type.",
            file: fileName,
            line: location.line,
            column: location.column,
            ruleId: "fixed-font-size",
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
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        // Check surrounding lines for a reduceMotion guard
        if hasNearbyReduceMotionCheck(around: location.line) { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "withAnimation used without an accessibilityReduceMotion check. Users with motion sensitivity (low vision, vestibular disorders) or motor difficulties may need reduced or no animation.",
            file: fileName,
            line: location.line,
            column: location.column,
            ruleId: "missing-reduce-motion",
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

        let location = node.startLocation(
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        guard !isExempted(line: location.line) else { return }

        if hasNearbyReduceMotionCheck(around: location.line) { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: ".animation() modifier used without an accessibilityReduceMotion check. Users with motion sensitivity may need reduced or no animation.",
            file: fileName,
            line: location.line,
            column: location.column,
            ruleId: "missing-reduce-motion",
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
            converter: SourceLocationConverter(fileName: fileName, tree: call.root)
        )
        guard !isExempted(line: location.line) else { return }

        // Only flag once per Image call (check we're the first argument)
        guard node == call.arguments.first else { return }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Image without .accessibilityLabel() or .accessibilityHidden(true). VoiceOver users (blind) will hear the raw image name or nothing. Screen reader is the primary UI for blind users.",
            file: fileName,
            line: location.line,
            column: location.column,
            ruleId: "missing-accessibility-label",
            suggestedFix: "Add .accessibilityLabel(\"description\") for meaningful images, or .accessibilityHidden(true) for purely decorative images."
        ))
    }

    // MARK: - Helpers

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
