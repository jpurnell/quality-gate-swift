import Foundation
import SwiftSyntax
import SwiftParser
import QualityGateCore

/// Walks View-conforming structs to check modifier chains on interactive elements.
///
/// Phase 2 rules:
/// - `hig.toolbar-tooltips`: Button in ToolbarItem without .help()
/// - `hig.keyboard-shortcuts`: Primary toolbar button without .keyboardShortcut()
/// - `hig.context-menus`: data-driven List without .contextMenu (advisory)
/// - `hig.toolbar-placement`: ToolbarItem without explicit placement
/// - `hig.secure-field` / `hig.text-input-content-type` / `hig.searchable` / `hig.tab-item-label`
/// - `hig.forced-color-scheme` / `hig.opaque-material`
final class ViewModifierVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let activePlatforms: HIGPlatform

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    private var insideToolbarItem = false
    private var toolbarItemHasPlacement = false
    private var toolbarItemLine: Int = 0
    private var toolbarButtonLocations: [(line: Int, column: Int)] = []
    private var toolbarHasHelp = false
    private var toolbarHasShortcut = false

    private var listDepth = 0
    private var listHasContextMenu = false
    private var listHasForEach = false
    private var listHasDataArgument = false
    private var listItemLine: Int = 0

    init(
        fileName: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        activePlatforms: HIGPlatform
    ) {
        self.fileName = fileName
        self.converter = converter
        self.sourceLines = sourceLines
        self.activePlatforms = activePlatforms
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - ToolbarItem Detection

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let calledName = extractCalledName(node)

        switch calledName {
        case "ToolbarItem", "ToolbarItemGroup":
            enterToolbarItem(node)
        case "List":
            enterListContext(node)
        default:
            break
        }

        if insideToolbarItem {
            checkToolbarModifiers(node)
        }
        if listDepth > 0 {
            checkListModifiers(node)
            if calledName == "ForEach" {
                listHasForEach = true
            }
        }

        checkForcedColorScheme(node)
        checkOpaqueMaterial(node)
        checkSecureField(node)
        checkTextInputContentType(node)
        checkSearchable(node)
        checkTabItemLabel(node)

        return .visitChildren
    }

    override func visitPost(_ node: FunctionCallExprSyntax) {
        let calledName = extractCalledName(node)

        if calledName == "ToolbarItem" || calledName == "ToolbarItemGroup" {
            exitToolbarItem()
        }
        if calledName == "List" {
            exitListContext()
        }
    }

    // MARK: - Toolbar Analysis

    private func enterToolbarItem(_ node: FunctionCallExprSyntax) {
        insideToolbarItem = true
        toolbarHasHelp = false
        toolbarHasShortcut = false
        toolbarButtonLocations = []
        let location = node.startLocation(converter: converter)
        toolbarItemLine = location.line

        toolbarItemHasPlacement = node.arguments.contains { arg in
            arg.label?.text == "placement"
        }
    }

    private func checkToolbarModifiers(_ node: FunctionCallExprSyntax) {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            switch name {
            case "help":
                toolbarHasHelp = true
            case "keyboardShortcut":
                toolbarHasShortcut = true
            case "Button":
                let location = node.startLocation(converter: converter)
                toolbarButtonLocations.append((line: location.line, column: location.column))
            default:
                break
            }
        }

        if let baseRef = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            if baseRef.baseName.text == "Button" {
                let location = node.startLocation(converter: converter)
                toolbarButtonLocations.append((line: location.line, column: location.column))
            }
        }
    }

    private func exitToolbarItem() {
        guard insideToolbarItem else { return }

        if !activePlatforms.isDisjoint(with: HIGRules.toolbarPlacement.platforms) && !toolbarItemHasPlacement {
            if checkExemption(near: toolbarItemLine, ruleId: HIGRules.toolbarPlacement.id) == nil {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: HIGRules.toolbarPlacement.message,
                    filePath: fileName,
                    lineNumber: toolbarItemLine,
                    columnNumber: 1,
                    ruleId: HIGRules.toolbarPlacement.id,
                    suggestedFix: HIGRules.toolbarPlacement.suggestedFix
                ))
            }
        }

        if !toolbarButtonLocations.isEmpty {
            if !activePlatforms.isDisjoint(with: HIGRules.toolbarTooltips.platforms) && !toolbarHasHelp {
                for loc in toolbarButtonLocations {
                    if checkExemption(near: loc.line, ruleId: HIGRules.toolbarTooltips.id) == nil {
                        diagnostics.append(Diagnostic(
                            severity: .note,
                            message: HIGRules.toolbarTooltips.message,
                            filePath: fileName,
                            lineNumber: loc.line,
                            columnNumber: loc.column,
                            ruleId: HIGRules.toolbarTooltips.id,
                            suggestedFix: HIGRules.toolbarTooltips.suggestedFix
                        ))
                    }
                }
            }

            if !activePlatforms.isDisjoint(with: HIGRules.keyboardShortcuts.platforms) && !toolbarHasShortcut {
                for loc in toolbarButtonLocations {
                    if checkExemption(near: loc.line, ruleId: HIGRules.keyboardShortcuts.id) == nil {
                        diagnostics.append(Diagnostic(
                            severity: .note,
                            message: HIGRules.keyboardShortcuts.message,
                            filePath: fileName,
                            lineNumber: loc.line,
                            columnNumber: loc.column,
                            ruleId: HIGRules.keyboardShortcuts.id,
                            suggestedFix: HIGRules.keyboardShortcuts.suggestedFix
                        ))
                    }
                }
            }
        }

        insideToolbarItem = false
    }

    // MARK: - List / ForEach Context Menu Detection

    private func enterListContext(_ node: FunctionCallExprSyntax) {
        listDepth += 1
        listHasContextMenu = false
        listHasForEach = false
        // A data-driven `List(collection) { ... }` produces rows directly; detect it
        // via an unlabeled leading argument (the collection). `List { ... }` with only
        // static content or references to extracted @ViewBuilder sections has none.
        listHasDataArgument = node.arguments.first.map { $0.label == nil } ?? false
        let location = node.startLocation(converter: converter)
        listItemLine = location.line
    }

    private func checkListModifiers(_ node: FunctionCallExprSyntax) {
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else { return }
        if member.declName.baseName.text == "contextMenu" {
            listHasContextMenu = true
        }
    }

    private func exitListContext() {
        guard listDepth > 0 else { return }

        // Only flag Lists that actually produce rows — either data-driven
        // (`List(items) { ... }`) or containing a direct `ForEach`. A `List { ... }`
        // whose content is static or delegated to extracted @ViewBuilder sections
        // has no items the visitor can inspect, so flagging it is a false positive.
        let listProducesItems = listHasDataArgument || listHasForEach

        if listProducesItems,
           !activePlatforms.isDisjoint(with: HIGRules.contextMenus.platforms) && !listHasContextMenu {
            if checkExemption(near: listItemLine, ruleId: HIGRules.contextMenus.id) == nil {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: HIGRules.contextMenus.message,
                    filePath: fileName,
                    lineNumber: listItemLine,
                    columnNumber: 1,
                    ruleId: HIGRules.contextMenus.id,
                    suggestedFix: HIGRules.contextMenus.suggestedFix
                ))
            }
        }

        listDepth -= 1
    }

    // MARK: - Foundations

    private static let materials: Set<String> = [
        "ultraThinMaterial", "thinMaterial", "regularMaterial", "thickMaterial", "ultraThickMaterial", "bar",
    ]

    /// `hig.forced-color-scheme`: `.preferredColorScheme(.dark/.light)` locks appearance.
    private func checkForcedColorScheme(_ node: FunctionCallExprSyntax) {
        guard !activePlatforms.isDisjoint(with: HIGRules.forcedColorScheme.platforms) else { return }
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "preferredColorScheme",
              let arg = node.arguments.first,
              let scheme = arg.expression.as(MemberAccessExprSyntax.self),
              ["dark", "light"].contains(scheme.declName.baseName.text) else {
            return
        }
        emit(HIGRules.forcedColorScheme, at: node)
    }

    /// `hig.opaque-material`: an opaque `Color` toolbar background where a material belongs.
    private func checkOpaqueMaterial(_ node: FunctionCallExprSyntax) {
        guard !activePlatforms.isDisjoint(with: HIGRules.opaqueMaterial.platforms) else { return }
        guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "toolbarBackground",
              let firstArg = node.arguments.first else {
            return
        }
        // A system material is fine.
        if let matMember = firstArg.expression.as(MemberAccessExprSyntax.self),
           Self.materials.contains(matMember.declName.baseName.text) {
            return
        }
        // Flag an explicit Color (Color(...) or Color.X). Bare members like .visible
        // (a Visibility, not a color) are conservatively ignored.
        if Self.isColorExpr(firstArg.expression) {
            emit(HIGRules.opaqueMaterial, at: node)
        }
    }

    private static func isColorExpr(_ expr: ExprSyntax) -> Bool {
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text == "Color"
        }
        if let member = expr.as(MemberAccessExprSyntax.self),
           let base = member.base?.as(DeclReferenceExprSyntax.self) {
            return base.baseName.text == "Color"
        }
        return false
    }

    // MARK: - Input rules

    private static let passwordKeywords: Set<String> = ["password", "passcode", "passphrase", "cvv"]
    private static let typedContentKeywords: Set<String> = [
        "email", "phone", "url", "website", "zip", "postal", "amount", "price", "number", "quantity",
    ]
    private static let searchKeywords: Set<String> = ["search", "query"]

    /// `hig.secure-field`: a password-labeled `TextField` should be a `SecureField`.
    private func checkSecureField(_ node: FunctionCallExprSyntax) {
        guard !activePlatforms.isDisjoint(with: HIGRules.secureField.platforms) else { return }
        guard extractCalledName(node) == "TextField",
              let label = firstStringLiteralArgument(node),
              Self.matchesKeyword(label, Self.passwordKeywords) else {
            return
        }
        emit(HIGRules.secureField, at: node)
    }

    /// `hig.text-input-content-type`: a typed field missing keyboard/content-type hints.
    private func checkTextInputContentType(_ node: FunctionCallExprSyntax) {
        guard !activePlatforms.isDisjoint(with: HIGRules.textInputContentType.platforms) else { return }
        let name = extractCalledName(node)
        guard name == "TextField" || name == "SecureField",
              let label = firstStringLiteralArgument(node),
              Self.matchesKeyword(label, Self.typedContentKeywords) else {
            return
        }
        if hasAncestorModifier(from: node, named: "keyboardType") { return }
        if hasAncestorModifier(from: node, named: "textContentType") { return }
        emit(HIGRules.textInputContentType, at: node)
    }

    /// `hig.searchable`: hand-rolled search `TextField`, or a `.searchable` prompt of "Search".
    private func checkSearchable(_ node: FunctionCallExprSyntax) {
        guard !activePlatforms.isDisjoint(with: HIGRules.searchableField.platforms) else { return }
        let name = extractCalledName(node)
        if name == "TextField",
           let label = firstStringLiteralArgument(node),
           Self.matchesKeyword(label, Self.searchKeywords) {
            emit(HIGRules.searchableField, at: node)
            return
        }
        if name == "searchable",
           let prompt = stringLiteralArgument(node, label: "prompt"),
           prompt.lowercased() == "search" {
            emit(HIGRules.searchableField, at: node)
        }
    }

    /// `hig.tab-item-label`: a `.tabItem` closure with an icon but no text/label.
    private func checkTabItemLabel(_ node: FunctionCallExprSyntax) {
        guard !activePlatforms.isDisjoint(with: HIGRules.tabItemLabel.platforms) else { return }
        guard extractCalledName(node) == "tabItem",
              let closure = node.trailingClosure else {
            return
        }
        let hasLabel = closureMentions(closure, identifiers: ["Text", "Label"])
        if !hasLabel {
            emit(HIGRules.tabItemLabel, at: node)
        }
    }

    // MARK: - Input-rule helpers

    private func emit(_ rule: HIGRuleDefinition, at node: some SyntaxProtocol) {
        let location = node.startLocation(converter: converter)
        if let override = checkExemption(near: location.line, ruleId: rule.id) {
            overrides.append(override)
            return
        }
        diagnostics.append(Diagnostic(
            severity: .note,
            message: rule.message,
            filePath: fileName,
            lineNumber: location.line,
            columnNumber: location.column,
            ruleId: rule.id,
            suggestedFix: rule.suggestedFix
        ))
    }

    private func firstStringLiteralArgument(_ node: FunctionCallExprSyntax) -> String? {
        guard let first = node.arguments.first, first.label == nil,
              let literal = first.expression.as(StringLiteralExprSyntax.self) else {
            return nil
        }
        return literal.representedLiteralValue
    }

    private func stringLiteralArgument(_ node: FunctionCallExprSyntax, label: String) -> String? {
        guard let arg = node.arguments.first(where: { $0.label?.text == label }),
              let literal = arg.expression.as(StringLiteralExprSyntax.self) else {
            return nil
        }
        return literal.representedLiteralValue
    }

    private func hasAncestorModifier(from node: some SyntaxProtocol, named: String) -> Bool {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if let call = parent.as(FunctionCallExprSyntax.self),
               let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == named {
                return true
            }
            current = parent
        }
        return false
    }

    private func closureMentions(_ closure: ClosureExprSyntax, identifiers: Set<String>) -> Bool {
        for token in closure.tokens(viewMode: .sourceAccurate) where identifiers.contains(token.text) {
            return true
        }
        return false
    }

    private static func matchesKeyword(_ text: String, _ keywords: Set<String>) -> Bool {
        let lower = text.lowercased()
        return keywords.contains { lower.contains($0) }
    }

    // MARK: - Helpers

    private func extractCalledName(_ node: FunctionCallExprSyntax) -> String {
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return ""
    }

    private func checkExemption(near line: Int, ruleId: String) -> DiagnosticOverride? {
        let linesToCheck = [line - 1, line]
            .filter { $0 >= 1 && $0 <= sourceLines.count }

        for lineNum in linesToCheck {
            let content = sourceLines[lineNum - 1]
            if content.contains(HIGRules.exemptionPrefix) {
                let justification = content
                    .components(separatedBy: HIGRules.exemptionPrefix)
                    .last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                return DiagnosticOverride(
                    ruleId: ruleId,
                    justification: justification,
                    filePath: fileName,
                    lineNumber: lineNum
                )
            }
        }
        return nil
    }
}
