import Foundation
import SwiftSyntax
import SwiftParser
import QualityGateCore

/// Walks View-conforming structs to check modifier chains on interactive elements.
///
/// Phase 2 rules:
/// - `hig.toolbar-tooltips`: Button in ToolbarItem without .help()
/// - `hig.keyboard-shortcuts`: Primary toolbar button without .keyboardShortcut()
/// - `hig.context-menus`: List/ForEach items without .contextMenu
/// - `hig.semantic-colors`: Hardcoded Color literals in View bodies
/// - `hig.toolbar-placement`: ToolbarItem without explicit placement
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
    private var listItemLine: Int = 0

    /// Hardcoded color names that should use semantic alternatives.
    private static let flaggedColors: Set<String> = [
        "blue", "red", "green", "orange", "purple", "pink", "yellow", "brown",
        "cyan", "indigo", "mint", "teal",
    ]

    /// Colors that are intentional and not flagged.
    private static let allowedColors: Set<String> = [
        "clear", "white", "black", "accentColor", "primary", "secondary",
    ]

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
        }

        checkSemanticColors(node)

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

        if !activePlatforms.isDisjoint(with: HIGRules.contextMenus.platforms) && !listHasContextMenu {
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

    // MARK: - Semantic Colors

    private func checkSemanticColors(_ node: FunctionCallExprSyntax) {
        guard !activePlatforms.isDisjoint(with: HIGRules.semanticColors.platforms) else { return }

        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let memberName = member.declName.baseName.text

            if let base = member.base?.as(DeclReferenceExprSyntax.self),
               base.baseName.text == "Color",
               Self.flaggedColors.contains(memberName) {
                let location = node.startLocation(converter: converter)
                if checkExemption(near: location.line, ruleId: HIGRules.semanticColors.id) == nil {
                    diagnostics.append(Diagnostic(
                        severity: .note,
                        message: HIGRules.semanticColors.message,
                        filePath: fileName,
                        lineNumber: location.line,
                        columnNumber: location.column,
                        ruleId: HIGRules.semanticColors.id,
                        suggestedFix: HIGRules.semanticColors.suggestedFix
                    ))
                }
            }
        }

        if let baseRef = node.calledExpression.as(DeclReferenceExprSyntax.self),
           baseRef.baseName.text == "Color" {
            let hasRGBArgs = node.arguments.contains { arg in
                arg.label?.text == "red" || arg.label?.text == "hue"
            }
            let hasSRGBArgs = node.arguments.contains { arg in
                arg.label?.text == ".sRGB" || arg.label?.text == "colorSpace"
            }
            if hasRGBArgs || hasSRGBArgs {
                let location = node.startLocation(converter: converter)
                if checkExemption(near: location.line, ruleId: HIGRules.semanticColors.id) == nil {
                    diagnostics.append(Diagnostic(
                        severity: .note,
                        message: HIGRules.semanticColors.message,
                        filePath: fileName,
                        lineNumber: location.line,
                        columnNumber: location.column,
                        ruleId: HIGRules.semanticColors.id,
                        suggestedFix: HIGRules.semanticColors.suggestedFix
                    ))
                }
            }
        }
    }

    // MARK: - MemberAccess for static Color properties (Color.blue, Color.red, etc.)

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard !activePlatforms.isDisjoint(with: HIGRules.semanticColors.platforms) else {
            return .visitChildren
        }

        if let base = node.base?.as(DeclReferenceExprSyntax.self),
           base.baseName.text == "Color" {
            let memberName = node.declName.baseName.text
            if Self.flaggedColors.contains(memberName) {
                let location = node.startLocation(converter: converter)
                if checkExemption(near: location.line, ruleId: HIGRules.semanticColors.id) == nil {
                    diagnostics.append(Diagnostic(
                        severity: .note,
                        message: HIGRules.semanticColors.message,
                        filePath: fileName,
                        lineNumber: location.line,
                        columnNumber: location.column,
                        ruleId: HIGRules.semanticColors.id,
                        suggestedFix: HIGRules.semanticColors.suggestedFix
                    ))
                }
            }
        }

        return .visitChildren
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
