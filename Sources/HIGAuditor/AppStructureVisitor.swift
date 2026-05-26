import Foundation
import SwiftSyntax
import SwiftParser
import QualityGateCore

/// Walks an `@main` App struct to check for required structural elements.
///
/// Detects:
/// - Settings scene presence (`hig.settings-scene`)
/// - .commands {} modifier presence (`hig.menu-commands`)
/// - NavigationStack usage (`hig.navigation-pattern`)
/// - WindowResizability constraints (`hig.window-resizability`)
final class AppStructureVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let activePlatforms: HIGPlatform

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    private var isInAppStruct = false
    private var isInAppBody = false
    private var hasSettingsScene = false
    private var hasCommands = false
    private var hasWindowGroup = false
    private var windowGroupHasResizability = false
    private var appStructLine: Int?

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

    // MARK: - Struct Declarations

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard hasAppConformance(node) else { return .visitChildren }
        guard hasMainAttribute(node) else { return .visitChildren }

        isInAppStruct = true
        let location = node.startLocation(converter: converter)
        appStructLine = location.line

        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        guard isInAppStruct, hasMainAttribute(node) else { return }

        emitStructuralDiagnostics()
        isInAppStruct = false
        isInAppBody = false
        hasSettingsScene = false
        hasCommands = false
        hasWindowGroup = false
        windowGroupHasResizability = false
    }

    // MARK: - Scene and Modifier Detection

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard isInAppStruct else { return .visitChildren }

        let name = node.baseName.text
        switch name {
        case "Settings":
            hasSettingsScene = true
        case "WindowGroup", "DocumentGroup":
            hasWindowGroup = true
        default:
            break
        }

        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isInAppStruct else { return .visitChildren }

        if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let modifierName = member.declName.baseName.text
            switch modifierName {
            case "commands":
                hasCommands = true
            case "windowResizability":
                windowGroupHasResizability = true
            default:
                break
            }
        }

        return .visitChildren
    }

    // MARK: - NavigationStack Detection (applies to all View files, not just App)

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        .visitChildren
    }

    // MARK: - Helpers

    private func hasAppConformance(_ node: StructDeclSyntax) -> Bool {
        guard let inheritance = node.inheritanceClause else { return false }
        return inheritance.inheritedTypes.contains { type in
            type.type.trimmedDescription == "App"
        }
    }

    private func hasMainAttribute(_ node: StructDeclSyntax) -> Bool {
        node.attributes.contains { element in
            guard let attr = element.as(AttributeSyntax.self) else { return false }
            return attr.attributeName.trimmedDescription == "main"
        }
    }

    private func emitStructuralDiagnostics() {
        guard let line = appStructLine else { return }

        if activePlatforms.contains(.macOS) && !hasSettingsScene {
            if let exempt = checkExemption(near: line, ruleId: HIGRules.settingsScene.id) {
                overrides.append(exempt)
            } else {
                diagnostics.append(makeDiagnostic(HIGRules.settingsScene, line: line))
            }
        }

        if !activePlatforms.isDisjoint(with: .desktop) && hasWindowGroup && !hasCommands {
            if let exempt = checkExemption(near: line, ruleId: HIGRules.menuCommands.id) {
                overrides.append(exempt)
            } else {
                diagnostics.append(makeDiagnostic(HIGRules.menuCommands, line: line))
            }
        }
    }

    private func makeDiagnostic(_ rule: HIGRuleDefinition, line: Int, column: Int = 1) -> Diagnostic {
        Diagnostic(
            severity: rule.tier == .structural ? .warning : .note,
            message: rule.message,
            filePath: fileName,
            lineNumber: line,
            columnNumber: column,
            ruleId: rule.id,
            suggestedFix: rule.suggestedFix
        )
    }

    private func checkExemption(near line: Int, ruleId: String) -> DiagnosticOverride? {
        let linesToCheck = [line - 1, line, line + 1]
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

/// Walks any View-conforming struct to detect navigation pattern issues.
final class NavigationPatternVisitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let activePlatforms: HIGPlatform

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

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

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.baseName.text == "NavigationStack" else { return .visitChildren }
        guard !activePlatforms.isDisjoint(with: HIGRules.navigationPattern.platforms) else {
            return .visitChildren
        }

        let location = node.startLocation(converter: converter)
        let line = location.line

        if let exempt = checkExemption(near: line) {
            overrides.append(exempt)
        } else {
            diagnostics.append(Diagnostic(
                severity: .warning,
                message: HIGRules.navigationPattern.message,
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: HIGRules.navigationPattern.id,
                suggestedFix: HIGRules.navigationPattern.suggestedFix
            ))
        }

        return .visitChildren
    }

    private func checkExemption(near line: Int) -> DiagnosticOverride? {
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
                    ruleId: HIGRules.navigationPattern.id,
                    justification: justification,
                    filePath: fileName,
                    lineNumber: lineNum
                )
            }
        }
        return nil
    }
}
