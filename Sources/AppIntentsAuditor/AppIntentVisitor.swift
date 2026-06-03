import Foundation
import SwiftSyntax
import SwiftParser
import QualityGateCore

/// SwiftSyntax-based visitor that audits App Intents declarations for
/// completeness, discoverability, and Apple Intelligence readiness.
public enum AppIntentVisitor {

    /// Analyze a Swift source string for App Intents completeness.
    ///
    /// Returns empty diagnostics if the file does not contain `import AppIntents`.
    public static func analyze(source: String, fileName: String) -> [Diagnostic] {
        guard source.contains("import AppIntents") else { return [] }

        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = Visitor(fileName: fileName, converter: converter)
        visitor.walk(tree)
        return visitor.emitDiagnostics()
    }
}

private final class Visitor: SyntaxVisitor {
    let fileName: String
    let converter: SourceLocationConverter

    var intents: [ExtractedIntent] = []
    var entities: [ExtractedEntity] = []
    var enums: [ExtractedEnum] = []
    var hasShortcutsProvider = false

    private var currentStructName: String?
    private var currentEnumName: String?
    private var currentInheritance: Set<String> = []
    private var currentAttributes: Set<String> = []

    init(fileName: String, converter: SourceLocationConverter) {
        self.fileName = fileName
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Struct declarations (AppIntent, AppEntity)

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let inheritance = inheritedTypeNames(node.inheritanceClause)
        let attributes = attributeNames(node.attributes)

        currentStructName = name
        currentInheritance = inheritance
        currentAttributes = attributes

        let loc = node.name.startLocation(converter: converter)

        if inheritance.contains("AppIntent") {
            var intent = ExtractedIntent(
                name: name,
                line: loc.line,
                column: loc.column
            )
            intent.hasAssistantIntent = attributes.contains("AssistantIntent")
            intents.append(intent)
        }

        if inheritance.contains("AppEntity") {
            var entity = ExtractedEntity(
                name: name,
                line: loc.line,
                column: loc.column
            )
            entity.hasAssistantEntity = attributes.contains("AssistantEntity")
            entities.append(entity)
        }

        if inheritance.contains("AppShortcutsProvider") {
            hasShortcutsProvider = true
        }

        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        currentStructName = nil
        currentInheritance = []
        currentAttributes = []
    }

    // MARK: - Enum declarations (AppEnum)

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let inheritance = inheritedTypeNames(node.inheritanceClause)
        let attributes = attributeNames(node.attributes)

        currentEnumName = name
        currentInheritance = inheritance
        currentAttributes = attributes

        if inheritance.contains("AppEnum") {
            let loc = node.name.startLocation(converter: converter)
            var extracted = ExtractedEnum(
                name: name,
                line: loc.line,
                column: loc.column
            )
            extracted.hasAssistantEnum = attributes.contains("AssistantEnum")
            enums.append(extracted)
        }

        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        currentEnumName = nil
        currentInheritance = []
        currentAttributes = []
    }

    // MARK: - Enum cases

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let enumName = currentEnumName,
              let idx = enums.lastIndex(where: { $0.name == enumName }) else {
            return .visitChildren
        }
        for element in node.elements {
            enums[idx].cases.append(element.name.text)
        }
        return .visitChildren
    }

    // MARK: - Member declarations (properties, methods)

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let binding = node.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
            return .visitChildren
        }
        let propName = pattern.identifier.text

        if let structName = currentStructName {
            if let intentIdx = intents.lastIndex(where: { $0.name == structName }) {
                handleIntentProperty(propName: propName, node: node, intentIdx: intentIdx)
            }
            if let entityIdx = entities.lastIndex(where: { $0.name == structName }) {
                handleEntityProperty(propName: propName, node: node, entityIdx: entityIdx)
            }
        }

        if let enumName = currentEnumName,
           let enumIdx = enums.lastIndex(where: { $0.name == enumName }) {
            handleEnumProperty(propName: propName, node: node, enumIdx: enumIdx)
        }

        return .visitChildren
    }

    private func handleIntentProperty(propName: String, node: VariableDeclSyntax, intentIdx: Int) {
        if propName == "description" {
            if let typeAnnotation = node.bindings.first?.typeAnnotation,
               typeAnnotation.type.trimmedDescription.contains("IntentDescription") {
                intents[intentIdx].hasDescription = true
            } else if let initializer = node.bindings.first?.initializer {
                let initText = initializer.value.trimmedDescription
                if initText.contains("IntentDescription") || initText.starts(with: "\"") {
                    intents[intentIdx].hasDescription = true
                }
            }
        }

        let attributes = attributeNames(node.attributes)
        if attributes.contains("Parameter") {
            let loc = node.startLocation(converter: converter)
            var param = ExtractedParameter(
                name: propName,
                line: loc.line,
                column: loc.column
            )
            param.hasTitle = parameterHasTitle(node.attributes)
            intents[intentIdx].parameters.append(param)
        }
    }

    private func handleEntityProperty(propName: String, node: VariableDeclSyntax, entityIdx: Int) {
        switch propName {
        case "displayRepresentation":
            entities[entityIdx].hasDisplayRepresentation = true
        case "typeDisplayRepresentation":
            entities[entityIdx].hasTypeDisplayRepresentation = true
        case "id":
            entities[entityIdx].hasId = true
        case "defaultQuery":
            entities[entityIdx].hasDefaultQuery = true
        default:
            break
        }
    }

    private func handleEnumProperty(propName: String, node: VariableDeclSyntax, enumIdx: Int) {
        switch propName {
        case "typeDisplayRepresentation":
            enums[enumIdx].hasTypeDisplayRepresentation = true
        case "caseDisplayRepresentations":
            if let initializer = node.bindings.first?.initializer {
                enums[enumIdx].displayedCases = extractDictionaryKeys(initializer.value)
            }
        default:
            break
        }
    }

    // MARK: - Function declarations (perform)

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == "perform",
           let structName = currentStructName,
           let idx = intents.lastIndex(where: { $0.name == structName }) {
            intents[idx].hasPerform = true
        }
        return .visitChildren
    }

    // MARK: - Diagnostic emission

    func emitDiagnostics() -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        for intent in intents {
            if !intent.hasDescription {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "AppIntent '\(intent.name)' is missing an IntentDescription.",
                    filePath: fileName,
                    lineNumber: intent.line,
                    columnNumber: intent.column,
                    ruleId: "appintent-no-description",
                    suggestedFix: "Add a `static var description: IntentDescription` property."
                ))
            }
            if !intent.hasAssistantIntent {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "AppIntent '\(intent.name)' is missing @AssistantIntent annotation for Apple Intelligence.",
                    filePath: fileName,
                    lineNumber: intent.line,
                    columnNumber: intent.column,
                    ruleId: "appintent-no-assistant-schema",
                    suggestedFix: "Add @AssistantIntent(schema: .system.<category>) to the struct."
                ))
            }
            for param in intent.parameters where !param.hasTitle {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "@Parameter '\(param.name)' in '\(intent.name)' is missing a title.",
                    filePath: fileName,
                    lineNumber: param.line,
                    columnNumber: param.column,
                    ruleId: "appintent-param-no-title",
                    suggestedFix: "Add title: argument: @Parameter(title: \"\(param.name.capitalized)\")."
                ))
            }
        }

        for entity in entities {
            if !entity.hasDisplayRepresentation {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "AppEntity '\(entity.name)' is missing displayRepresentation.",
                    filePath: fileName,
                    lineNumber: entity.line,
                    columnNumber: entity.column,
                    ruleId: "appintent-entity-no-display",
                    suggestedFix: "Add a `var displayRepresentation: DisplayRepresentation` property."
                ))
            }
            if !entity.hasTypeDisplayRepresentation {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "AppEntity '\(entity.name)' is missing typeDisplayRepresentation.",
                    filePath: fileName,
                    lineNumber: entity.line,
                    columnNumber: entity.column,
                    ruleId: "appintent-entity-no-type-display",
                    suggestedFix: "Add a `static var typeDisplayRepresentation: TypeDisplayRepresentation` property."
                ))
            }
            if !entity.hasAssistantEntity {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "AppEntity '\(entity.name)' is not annotated with @AssistantEntity for Apple Intelligence.",
                    filePath: fileName,
                    lineNumber: entity.line,
                    columnNumber: entity.column,
                    ruleId: "appintent-entity-not-assistant",
                    suggestedFix: "Add @AssistantEntity(schema: .system.<category>) to the struct."
                ))
            }
        }

        for appEnum in enums {
            if !appEnum.hasTypeDisplayRepresentation {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "AppEnum '\(appEnum.name)' is missing typeDisplayRepresentation.",
                    filePath: fileName,
                    lineNumber: appEnum.line,
                    columnNumber: appEnum.column,
                    ruleId: "appintent-enum-no-display",
                    suggestedFix: "Add a `static var typeDisplayRepresentation: TypeDisplayRepresentation` property."
                ))
            }
            if !appEnum.hasAssistantEnum {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "AppEnum '\(appEnum.name)' is not annotated with @AssistantEnum for Apple Intelligence.",
                    filePath: fileName,
                    lineNumber: appEnum.line,
                    columnNumber: appEnum.column,
                    ruleId: "appintent-enum-not-assistant",
                    suggestedFix: "Add @AssistantEnum to the enum declaration."
                ))
            }
            let missingCases = appEnum.cases.filter { !appEnum.displayedCases.contains($0) }
            for caseName in missingCases {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "AppEnum '\(appEnum.name)' case '\(caseName)' is not in caseDisplayRepresentations.",
                    filePath: fileName,
                    lineNumber: appEnum.line,
                    columnNumber: appEnum.column,
                    ruleId: "appintent-enum-case-no-display",
                    suggestedFix: "Add .\(caseName) to the caseDisplayRepresentations dictionary."
                ))
            }
        }

        return diagnostics
    }

    // MARK: - Helpers

    private func inheritedTypeNames(_ clause: InheritanceClauseSyntax?) -> Set<String> {
        guard let clause else { return [] }
        var names: Set<String> = []
        for inherited in clause.inheritedTypes {
            if let id = inherited.type.as(IdentifierTypeSyntax.self) {
                names.insert(id.name.text)
            }
        }
        return names
    }

    private func attributeNames(_ attributes: AttributeListSyntax) -> Set<String> {
        var names: Set<String> = []
        for attr in attributes {
            if let attribute = attr.as(AttributeSyntax.self) {
                if let id = attribute.attributeName.as(IdentifierTypeSyntax.self) {
                    names.insert(id.name.text)
                }
            }
        }
        return names
    }

    private func parameterHasTitle(_ attributes: AttributeListSyntax) -> Bool {
        for attr in attributes {
            guard let attribute = attr.as(AttributeSyntax.self),
                  let id = attribute.attributeName.as(IdentifierTypeSyntax.self),
                  id.name.text == "Parameter" else { continue }
            if let args = attribute.arguments?.as(LabeledExprListSyntax.self) {
                for arg in args {
                    if arg.label?.text == "title" {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func extractDictionaryKeys(_ expr: ExprSyntax) -> Set<String> {
        var keys: Set<String> = []
        guard let dict = expr.as(DictionaryExprSyntax.self) else { return keys }
        guard let elements = dict.content.as(DictionaryElementListSyntax.self) else { return keys }
        for element in elements {
            if let memberAccess = element.key.as(MemberAccessExprSyntax.self) {
                keys.insert(memberAccess.declName.baseName.text)
            }
        }
        return keys
    }
}
