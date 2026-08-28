import AccessibilityCore
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Namespaced rule identifiers for the SwiftUI accessibility detector.
enum SwiftUIAccessibilityRule {
    static let fixedFontSize = "a11y.swiftui.fixed-font-size"
    static let missingReduceMotion = "a11y.swiftui.missing-reduce-motion"
    static let missingAccessibilityLabel = "a11y.swiftui.missing-accessibility-label"
    static let customFontNoRelativeTo = "a11y.swiftui.custom-font-no-relativeto"
    static let tapGestureMissingButtonTrait = "a11y.swiftui.tap-gesture-missing-button-trait"
    static let hardcodedColor = "a11y.swiftui.hardcoded-color-string"
    static let colorOnlyDifferentiation = "a11y.swiftui.color-only-differentiation"
    static let missingAccessibilityHint = "a11y.swiftui.missing-accessibility-hint"
    static let decorativeImageNotHidden = "a11y.swiftui.decorative-image-not-hidden"
    static let materialNoReduceTransparency = "a11y.swiftui.material-no-reduce-transparency"
    static let standardShortcutOverride = "a11y.swiftui.standard-shortcut-override"
    static let hitTargetTooSmall = "a11y.swiftui.hit-target-too-small"
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

    /// Names of properties declared `@ScaledMetric` in this file.
    ///
    /// `@ScaledMetric` is the API for keeping a designed point size while still growing
    /// with Dynamic Type. A size driven by one is therefore not a fixed size, even though
    /// it is spelled `.system(size:)` — the spelling is all this rule can see, so without
    /// this the correct fix and the defect look identical.
    private let scaledMetricNames: Set<String>

    init(fileName: String, source: String, exemptionPatterns: [String], tree: SourceFileSyntax) {
        self.fileName = fileName
        self.source = source
        self.scaledMetricNames = Self.scaledMetricProperties(in: tree)
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.lines
        self.converter = SourceLocationConverter(fileName: fileName, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Rule: fixed-font-size

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        checkFixedFontSize(node)
        checkWithAnimationMissingReduceMotion(node)
        checkCustomFontNoRelativeTo(node)
        checkTapGestureMissingButtonTrait(node)
        checkHardcodedColor(node)
        checkColorOnlyDifferentiation(node)
        checkMissingAccessibilityHint(node)
        checkMaterialNoReduceTransparency(node)
        checkStandardShortcutOverride(node)
        checkHitTargetTooSmall(node)
        return .visitChildren
    }

    /// Detects a translucent material or `.blur` without a Reduce Transparency guard in
    /// the file — people who enable Reduce Transparency need a solid fallback.
    private func checkMaterialNoReduceTransparency(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return }
        let name = member.declName.baseName.text
        let materials: Set<String> = ["ultraThinMaterial", "thinMaterial", "regularMaterial", "thickMaterial", "ultraThickMaterial"]

        var isTransparencyEffect = false
        if name == "blur" {
            isTransparencyEffect = true
        } else if ["background", "fill", "foregroundStyle", "overlay"].contains(name),
                  let arg = node.arguments.first,
                  let materialMember = arg.expression.as(MemberAccessExprSyntax.self),
                  materials.contains(materialMember.declName.baseName.text) {
            isTransparencyEffect = true
        }
        guard isTransparencyEffect else { return }
        if source.contains("accessibilityReduceTransparency") || source.contains("reduceTransparency") { return }

        let location = member.period.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.materialNoReduceTransparency) {
            overrides.append(override)
            return
        }
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Translucent material/blur without honoring Reduce Transparency — provide a solid fallback. — \(AccessibilityPrinciple.respectVisualPrefs.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.materialNoReduceTransparency,
            suggestedFix: "Read @Environment(\\.accessibilityReduceTransparency) and use a solid color background when it is on."
        ))
    }

    /// The key each standard `CommandGroupPlacement` already owns.
    ///
    /// Binding one of these *inside its own placement* is the system behaviour, not an
    /// override of it — the placement is the author declaring which standard slot the command
    /// occupies. `.textFormatting` is deliberately absent: it has no single canonical key, so
    /// a reserved key bound there is still a repurposing and still warns.
    private static let standardPlacementKeys: [String: Set<String>] = [
        "newItem": ["n"],
        "saveItem": ["s"],
        "printItem": ["p"],
        "undoRedo": ["z"],
        "pasteboard": ["x", "c", "v", "a"],
        // Settings is the standard owner of Command-comma, exactly as newItem owns
        // Command-N. An app placing its own Settings item here is adopting the
        // system convention, not repurposing the key.
        "appSettings": [","],
    ]

    /// The standard `CommandGroup` placement a call sits lexically inside, if any.
    ///
    /// Only `replacing:`, `before:` and `after:` count. A `CommandMenu("Game")` is a custom
    /// menu rather than a standard placement, so a reserved key bound in one is exactly the
    /// repurposing this rule exists to catch and is left flagged.
    private func enclosingCommandGroupPlacement(from node: some SyntaxProtocol) -> String? {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if let call = parent.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "CommandGroup",
               let placement = call.arguments.first,
               let label = placement.label?.text,
               ["replacing", "before", "after"].contains(label),
               let member = placement.expression.as(MemberAccessExprSyntax.self) {
                return member.declName.baseName.text
            }
            current = parent
        }
        return nil
    }

    /// Detects `.keyboardShortcut` binding a system-reserved key with Command — likely
    /// overriding standard system behavior rather than using the standard command.
    private func checkStandardShortcutOverride(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "keyboardShortcut" else {
            return
        }
        let reservedKeys: Set<String> = ["c", "v", "x", "z", "a", "s", "f", "w", "q", "n", "p", "h", "m", ","]
        guard let firstArg = node.arguments.first,
              let keyLiteral = firstArg.expression.as(StringLiteralExprSyntax.self),
              let key = keyLiteral.representedLiteralValue,
              reservedKeys.contains(key.lowercased()) else {
            return
        }
        // Only Command-only bindings (absent modifiers default to .command); leave
        // multi-modifier combos (usually custom app shortcuts) alone.
        let modifiersArg = node.arguments.first { $0.label?.text == "modifiers" }
        let isCommandOnly: Bool
        if let modifiersArg {
            isCommandOnly = modifiersArg.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "command"
        } else {
            isCommandOnly = true
        }
        guard isCommandOnly else { return }

        // A reserved key bound inside the standard menu placement that *owns* that key is the
        // canonical form, not a repurposing — and it is the form this rule's own suggestedFix
        // asks for. Deleting the modifier is not an available fix either: `CommandGroup` does
        // not confer its placement's shortcut on a custom Button, so removing it silently
        // deletes the shortcut from the app. Verified against a real `NSApp.mainMenu` dump.
        if let placement = enclosingCommandGroupPlacement(from: node),
           Self.standardPlacementKeys[placement]?.contains(key.lowercased()) == true {
            return
        }

        let location = member.period.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.standardShortcutOverride) {
            overrides.append(override)
            return
        }
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Binds a system-reserved shortcut (Command-\(key.uppercased())). Verify you aren't overriding standard system behavior. — \(AccessibilityPrinciple.keyboardConsistency.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.standardShortcutOverride,
            suggestedFix: "Prefer the standard command (e.g. CommandGroup / .cut/.copy/.paste) instead of rebinding a reserved shortcut on a custom control."
        ))
    }

    /// Detects a `Button` constrained to a fixed frame smaller than 44x44 pt with no
    /// compensating `.padding` — too small a hit target for many people.
    private func checkHitTargetTooSmall(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "frame" else {
            return
        }
        // Both width and height present and below the 44pt floor.
        guard let width = Self.numericArg(node, label: "width"), width < 44,
              let height = Self.numericArg(node, label: "height"), height < 44 else {
            return
        }
        // Walk the base chain: only Button controls, and skip when padding compensates.
        var base: ExprSyntax? = member.base
        var isButton = false
        var hasPadding = false
        while let expr = base {
            if let call = expr.as(FunctionCallExprSyntax.self) {
                if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
                   ref.baseName.text == "Button" {
                    isButton = true
                    break
                }
                if let innerMember = call.calledExpression.as(MemberAccessExprSyntax.self) {
                    if innerMember.declName.baseName.text == "padding" { hasPadding = true }
                    base = innerMember.base
                    continue
                }
            }
            base = expr.as(MemberAccessExprSyntax.self)?.base
        }
        guard isButton, !hasPadding else { return }

        let location = member.period.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.hitTargetTooSmall) {
            overrides.append(override)
            return
        }
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Button constrained below the 44x44 pt minimum hit target. — \(AccessibilityPrinciple.sufficientTarget.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.hitTargetTooSmall,
            suggestedFix: "Give the control at least a 44x44 pt tappable area (increase the frame, or add .padding / .contentShape to extend the hit region)."
        ))
    }

    /// Returns the numeric literal value of a labeled argument, if present and a plain number.
    private static func numericArg(_ node: FunctionCallExprSyntax, label: String) -> Double? {
        guard let arg = node.arguments.first(where: { $0.label?.text == label }) else { return nil }
        if let intLit = arg.expression.as(IntegerLiteralExprSyntax.self) {
            return Double(intLit.literal.text)
        }
        if let floatLit = arg.expression.as(FloatLiteralExprSyntax.self) {
            return Double(floatLit.literal.text)
        }
        return nil
    }

    /// Detects hardcoded `Color(...)` initializers (RGB / white / HSB / hex) that bypass
    /// Dark Mode and contrast adaptation. Asset-catalog and system colors are left alone.
    private func checkHardcodedColor(_ node: FunctionCallExprSyntax) {
        guard let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
              ref.baseName.text == "Color" else {
            return
        }
        let componentLabels: Set<String> = ["red", "green", "blue", "white", "hue", "saturation", "brightness", "hex"]
        // A component carried by a property or parameter is chosen at runtime — a
        // theme colour, a mode identity passed through attributes — and there is no
        // literal for the suggested fix to replace. Only a literal is hardcoded.
        let hasLiteralComponent = node.arguments.contains { arg in
            guard let label = arg.label?.text, componentLabels.contains(label) else { return false }
            return Self.isLiteralExpression(arg.expression)
        }
        guard hasLiteralComponent else { return }

        let location = node.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.hardcodedColor) {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Hardcoded color value bypasses Dark Mode and contrast adaptation. — \(AccessibilityPrinciple.respectVisualPrefs.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.hardcodedColor,
            suggestedFix: "Use an asset-catalog color (Color(\"Name\")) or a system/semantic color (Color(.systemBackground), .primary) so it adapts to appearance and accessibility settings."
        ))
    }

    /// Whether an expression is a literal the author wrote in place.
    private static func isLiteralExpression(_ expr: ExprSyntax) -> Bool {
        expr.is(StringLiteralExprSyntax.self)
            || expr.is(IntegerLiteralExprSyntax.self)
            || expr.is(FloatLiteralExprSyntax.self)
    }

    /// Modifiers that change something a colour-blind user can still perceive.
    private static let nonColorCompanionModifiers: Set<String> = [
        "opacity", "font", "fontWeight", "bold", "italic",
        "symbolVariant", "scaleEffect", "blur", "saturation", "strikethrough"
    ]

    /// Whether some other modifier in the same chain also varies on a condition and
    /// changes something other than colour, so colour is not the sole signal.
    private static func hasNonColorCompanion(inChainOf node: FunctionCallExprSyntax) -> Bool {
        // Modifiers below this one appear in its base; modifiers above it are its
        // ancestors. Climb to the outermost call so the whole chain is in scope.
        var root = Syntax(node)
        while let parent = root.parent,
              parent.is(MemberAccessExprSyntax.self) || parent.is(FunctionCallExprSyntax.self) {
            root = parent
        }
        return containsStateVaryingCompanion(root)
    }

    private static func containsStateVaryingCompanion(_ node: Syntax) -> Bool {
        if let call = node.as(FunctionCallExprSyntax.self) {
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               nonColorCompanionModifiers.contains(member.declName.baseName.text),
               let first = call.arguments.first,
               ternaryBranches(first.expression) != nil {
                return true
            }
            // `Image(systemName: on ? "a" : "b")` swaps the glyph itself.
            if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
               ref.baseName.text == "Image",
               let first = call.arguments.first,
               first.label?.text == "systemName",
               ternaryBranches(first.expression) != nil {
                return true
            }
            // `Text(on ? "Saved" : "Save")` changes the words. This is the strongest
            // companion of the lot — a colour-blind reader gets the state by reading, with
            // no inference from weight or opacity — and it was the one the rule missed.
            // WineTaster's "Results saved for X" / "Save results for X" button was flagged
            // for colour-only signalling while stating its state in plain language.
            if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
               ref.baseName.text == "Text",
               let first = call.arguments.first,
               first.label == nil,
               ternaryBranches(first.expression) != nil {
                return true
            }
        }
        for child in node.children(viewMode: .sourceAccurate) where containsStateVaryingCompanion(child) {
            return true
        }
        return false
    }

    /// Detects a color-only state signal: a `.foregroundColor`/`.foregroundStyle`/`.tint`
    /// whose value is a condition-selected color, with no Differentiate-Without-Color guard
    /// in the file. Color must not be the sole differentiator (Color blind).
    private func checkColorOnlyDifferentiation(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              ["foregroundColor", "foregroundStyle", "tint"].contains(member.declName.baseName.text) else {
            return
        }
        guard let firstArg = node.arguments.first,
              let (thenExpr, elseExpr) = Self.ternaryBranches(firstArg.expression),
              Self.looksLikeColor(thenExpr),
              Self.looksLikeColor(elseExpr) else {
            return
        }
        // Respect an explicit Differentiate Without Color path anywhere in the file.
        if source.contains("accessibilityDifferentiateWithoutColor") || source.contains("differentiateWithoutColor") {
            return
        }
        // A sibling modifier that varies on a condition and changes something other
        // than colour — an opacity, a weight, a symbol variant — is the companion
        // this rule asks for, and one a colour-blind user can actually see.
        if Self.hasNonColorCompanion(inChainOf: node) { return }

        let location = member.period.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.colorOnlyDifferentiation) {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "State conveyed by color alone (a condition selects between colors) with no shape/text/symbol companion. — \(AccessibilityPrinciple.notColorAlone.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.colorOnlyDifferentiation,
            suggestedFix: "Add a non-color differentiator (an SF Symbol, shape, or text label that also changes with state), or gate on @Environment(\\.accessibilityDifferentiateWithoutColor)."
        ))
    }

    /// Detects a deliberately-labeled custom tap control (`.onTapGesture` + `.accessibilityLabel`)
    /// that lacks an `.accessibilityHint` describing the result of the action.
    private func checkMissingAccessibilityHint(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "onTapGesture" else {
            return
        }
        guard hasModifierInChain(from: node, named: "accessibilityLabel") else { return }
        if hasModifierInChain(from: node, named: "accessibilityHint") { return }

        let location = member.period.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.missingAccessibilityHint) {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Labeled custom control has no accessibilityHint — VoiceOver users may not know what activating it does. — \(AccessibilityPrinciple.textAlternative.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.missingAccessibilityHint,
            suggestedFix: "Add .accessibilityHint(\"...\") describing the result of the action for non-obvious controls."
        ))
    }

    /// Extracts the then/else branches of a ternary, handling both the folded
    /// `TernaryExprSyntax` and the unfolded `SequenceExprSyntax` form that
    /// `SwiftParser.parse` produces by default (`[cond, UnresolvedTernaryExpr(then), else]`).
    private static func ternaryBranches(_ expr: ExprSyntax) -> (ExprSyntax, ExprSyntax)? {
        if let ternary = expr.as(TernaryExprSyntax.self) {
            return (ternary.thenExpression, ternary.elseExpression)
        }
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elements = Array(seq.elements)
            guard let idx = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
                  let unresolved = elements[idx].as(UnresolvedTernaryExprSyntax.self),
                  idx + 1 < elements.count else {
                return nil
            }
            return (unresolved.thenExpression, elements[idx + 1])
        }
        return nil
    }

    /// Heuristic: an expression that resolves to a color — a member access (`.red`,
    /// `Color.red`) or a `Color(...)` initializer.
    private static func looksLikeColor(_ expr: ExprSyntax) -> Bool {
        if expr.is(MemberAccessExprSyntax.self) { return true }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text == "Color"
        }
        return false
    }

    /// Detects `Font.custom(_:size:)` without the `relativeTo:` overload — a custom font
    /// with a fixed size does not scale with Dynamic Type (Low vision).
    private func checkCustomFontNoRelativeTo(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "custom" else {
            return
        }
        let hasSize = node.arguments.contains { $0.label?.text == "size" }
        let hasRelativeTo = node.arguments.contains { $0.label?.text == "relativeTo" }
        // `fixedSize:` (no `size:` label) is a deliberate opt-out and is left alone.
        guard hasSize, !hasRelativeTo else { return }

        let location = node.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.customFontNoRelativeTo) {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Custom font uses a fixed size (no relativeTo:) and won't scale with Dynamic Type. — \(AccessibilityPrinciple.scalableText.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.customFontNoRelativeTo,
            suggestedFix: "Use Font.custom(_:size:relativeTo:) so the custom font scales with Dynamic Type, e.g. .font(.custom(\"Name\", size: 15, relativeTo: .body))."
        ))
    }

    /// Detects `.onTapGesture` on a view that lacks `.accessibilityAddTraits(.isButton)` —
    /// VoiceOver won't announce a bare tappable view as an actionable control (Blind, Motor).
    private func checkTapGestureMissingButtonTrait(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "onTapGesture" else {
            return
        }
        if hasModifierInChain(from: node, named: "accessibilityAddTraits") { return }

        // A named accessibility action is the API Apple's guidance points at for a gesture with
        // no visible control, and on a container it is the better answer rather than merely an
        // acceptable one: `.isButton` on a scrollable map makes VoiceOver announce the whole
        // map as a single button, which is worse than the state this rule is complaining about.
        if hasModifierInChain(from: node, named: "accessibilityAction") { return }

        // A multi-tap gesture is an accelerator layered over another affordance, not the
        // primary way to operate a control. A single tap with no trait is the real case.
        if let count = Self.numericArg(node, label: "count"), count >= 2 { return }

        let location = member.period.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.tapGestureMissingButtonTrait) {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "onTapGesture without a button trait — VoiceOver won't announce this custom control as actionable. — \(AccessibilityPrinciple.operableAltInput.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.tapGestureMissingButtonTrait,
            suggestedFix: "Add .accessibilityAddTraits(.isButton) to the tappable view (and an .accessibilityLabel if it has no text)."
        ))
    }

    /// Property names carrying the `@ScaledMetric` attribute anywhere in the file.
    private static func scaledMetricProperties(in tree: SourceFileSyntax) -> Set<String> {
        final class Walker: SyntaxVisitor {
            var names: Set<String> = []
            override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
                let isScaled = node.attributes.contains { attribute in
                    attribute.as(AttributeSyntax.self)?
                        .attributeName.trimmedDescription == "ScaledMetric"
                }
                if isScaled {
                    for binding in node.bindings {
                        if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                            names.insert(pattern.identifier.text)
                        }
                    }
                }
                return .visitChildren
            }
        }
        let walker = Walker(viewMode: .sourceAccurate)
        walker.walk(tree)
        return walker.names
    }

    /// Detects `.font(.system(size: N))` — should use semantic text styles
    /// for Dynamic Type support (Low vision, Motor).
    private func checkFixedFontSize(_ node: FunctionCallExprSyntax) {
        // Match: .system(size: ...)
        guard let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
              memberAccess.declName.baseName.text == "system" else {
            return
        }

        guard let sizeArg = node.arguments.first(where: { $0.label?.text == "size" }) else { return }

        // A size that reads a `@ScaledMetric` property already grows with Dynamic Type.
        if let ref = sizeArg.expression.as(DeclReferenceExprSyntax.self),
           scaledMetricNames.contains(ref.baseName.text) {
            return
        }
        if let member = sizeArg.expression.as(MemberAccessExprSyntax.self),
           member.base?.trimmedDescription == "self",
           scaledMetricNames.contains(member.declName.baseName.text) {
            return
        }

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

        // `TimelineView(.animation(minimumInterval:))` is a TimelineViewSchedule —
        // a render clock that decides how often the view redraws, not a view
        // animation. Gating one on Reduce Motion stops the view updating at all.
        // A schedule is written as an implicit member expression and so has no
        // base; the view modifier is always applied to something.
        guard node.base != nil else { return }

        // `.animation(.none, …)` and `.animation(nil, …)` are already the
        // reduced-motion outcome, so there is nothing to guard.
        if let call = node.parent?.as(FunctionCallExprSyntax.self),
           let first = call.arguments.first,
           first.label == nil {
            let animation = first.expression.trimmedDescription
            if animation == ".none" || animation == "nil" { return }
        }

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

        // A-3: an Image used as a `.background`/`.overlay` is decorative — it should be
        // hidden from VoiceOver, not labeled. Handle it separately so the two rules don't
        // both fire on the same image.
        if isBackgroundOrOverlayArgument(call) {
            checkDecorativeImageNotHidden(call, firstArg: node)
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

    /// A decorative image (`.background`/`.overlay`) should be hidden from VoiceOver.
    private func checkDecorativeImageNotHidden(_ call: FunctionCallExprSyntax, firstArg: LabeledExprSyntax) {
        if hasModifierInChain(from: call, named: "accessibilityHidden") { return }
        guard firstArg == call.arguments.first else { return }

        let location = call.startLocation(converter: converter)
        if let override = overrideIfExempted(line: location.line, ruleId: SwiftUIAccessibilityRule.decorativeImageNotHidden) {
            overrides.append(override)
            return
        }
        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Decorative image (background/overlay) not hidden from VoiceOver — it adds noise for screen-reader users. — \(AccessibilityPrinciple.textAlternative.higAnchor)",
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: SwiftUIAccessibilityRule.decorativeImageNotHidden,
            suggestedFix: "Add .accessibilityHidden(true) to the decorative image, or use Image(decorative:)."
        ))
    }

    /// True when the given `Image(...)` call is an argument to a `.background`/`.overlay`
    /// modifier (i.e. it's decorative by position).
    private func isBackgroundOrOverlayArgument(_ call: FunctionCallExprSyntax) -> Bool {
        guard let labeledExpr = call.parent?.as(LabeledExprSyntax.self),
              let list = labeledExpr.parent?.as(LabeledExprListSyntax.self),
              let enclosing = list.parent?.as(FunctionCallExprSyntax.self),
              let member = enclosing.calledExpression.as(MemberAccessExprSyntax.self) else {
            return false
        }
        return ["background", "overlay"].contains(member.declName.baseName.text)
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
