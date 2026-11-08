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
        analyzeWithOverrides(source: source, fileName: fileName).diagnostics
    }

    /// Analyze a source string, also returning the exposure exemptions it recorded.
    ///
    /// An intent may decline a surface with `// appintents:exempt <surface> — <reason>`, where
    /// the surface is `siri`, `shortcuts` or `mcp`. Only `siri` has a rule to answer today; the
    /// other two are accepted so the syntax does not change when theirs arrive. A marker with no
    /// reason does not count and is reported; one with a reason silences the finding and is
    /// recorded, so every opt-out is visible in the override report.
    public static func analyzeWithOverrides(
        source: String, fileName: String
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        guard source.contains("import AppIntents") else { return ([], []) }

        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: fileName, tree: tree)
        let visitor = Visitor(
            fileName: fileName, converter: converter,
            sourceLines: source.lines)
        visitor.walk(tree)
        let diagnostics = visitor.emitDiagnostics()
        return (diagnostics, visitor.overrides)
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

    let sourceLines: [String]
    private(set) var overrides: [DiagnosticOverride] = []

    /// The surfaces an intent may decline.
    private static let surfaces: Set<String> = ["siri", "shortcuts", "mcp", "auth"]
    private static let exemptPrefix = "appintents:exempt"

    init(fileName: String, converter: SourceLocationConverter, sourceLines: [String]) {
        self.fileName = fileName
        self.converter = converter
        self.sourceLines = sourceLines
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
            intent.declarationLine = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
            // `@AppIntent(.tool)` and `@AppIntent(schema:)` are the macros; `AssistantIntent` and
            // `ToolIntent` are the protocols they conform the type to. `@AssistantIntent` is not
            // a macro, but it is still accepted so a file that wrote it is not newly flagged.
            intent.hasAssistantIntent = attributes.contains("AppIntent")
                || attributes.contains("AssistantIntent")
                || !inheritance.isDisjoint(with: ["AssistantIntent", "ToolIntent"])
            intent.isWidgetConfiguration = inheritance.contains("WidgetConfigurationIntent")
            intent.isTool = hasToolTrait(node.attributes) || inheritance.contains("ToolIntent")
            intents.append(intent)
        }

        if inheritance.contains("AppEntity") {
            var entity = ExtractedEntity(
                name: name,
                line: loc.line,
                column: loc.column
            )
            entity.hasAssistantEntity = attributes.contains("AppEntity")
                || attributes.contains("AssistantEntity")
                || inheritance.contains("AssistantEntity")
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
            extracted.hasAssistantEnum = attributes.contains("AppEnum")
                || attributes.contains("AssistantEnum")
                || inheritance.contains("AssistantEnum")
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

        if propName == "isDiscoverable",
           node.bindings.first?.initializer?.value.trimmedDescription == "false" {
            intents[intentIdx].isHiddenFromShortcuts = true
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
        let wrapper = entityPropertyAttribute(node.attributes)
        switch propName {
        case "displayRepresentation":
            entities[entityIdx].hasDisplayRepresentation = true
        case "typeDisplayRepresentation":
            entities[entityIdx].hasTypeDisplayRepresentation = true
        case "id":
            entities[entityIdx].hasId = true
        case "defaultQuery":
            entities[entityIdx].hasDefaultQuery = true
        case "authenticationPolicy":
            entities[entityIdx].hasAuthenticationPolicy = true
        default:
            break
        }

        if let wrapper, !isInternal(wrapper), !hasArgument("authenticationPolicy", in: wrapper),
           Self.looksSensitive(propName) {
            let loc = node.startLocation(converter: converter)
            entities[entityIdx].sensitiveProperties.append(
                ExtractedEntityProperty(name: propName, line: loc.line, column: loc.column))
        }

        if let wrapper,
           !hasArgument("description", in: wrapper),
           !isInternal(wrapper) {
            let loc = node.startLocation(converter: converter)
            entities[entityIdx].undescribedProperties.append(
                ExtractedEntityProperty(name: propName, line: loc.line, column: loc.column))
        }
    }

    private static let entityPropertyWrappers: Set<String> = ["Property", "DeferredProperty", "ComputedProperty"]

    private func entityPropertyAttribute(_ attributes: AttributeListSyntax) -> AttributeSyntax? {
        for attr in attributes {
            guard let attribute = attr.as(AttributeSyntax.self),
                  let id = attribute.attributeName.as(IdentifierTypeSyntax.self),
                  Self.entityPropertyWrappers.contains(id.name.text) else { continue }
            return attribute
        }
        return nil
    }

    /// `@AppIntent(.tool)` or `@AppIntent(.tool, schema:)`: the unlabeled `.tool` argument.
    private func hasToolTrait(_ attributes: AttributeListSyntax) -> Bool {
        for attr in attributes {
            guard let attribute = attr.as(AttributeSyntax.self),
                  attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "AppIntent",
                  let args = attribute.arguments?.as(LabeledExprListSyntax.self) else { continue }
            if args.contains(where: {
                $0.label == nil && $0.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "tool"
            }) { return true }
        }
        return false
    }

    /// Words that mark money, credentials and health data. A name heuristic, which is why the rule
    /// it feeds has a recorded decline.
    private static let sensitiveWords: Set<String> = [
        "password", "passcode", "secret", "token", "balance", "salary", "ssn", "diagnosis", "medication",
    ]

    static func looksSensitive(_ name: String) -> Bool {
        var words: [String] = []
        var current = ""
        for character in name {
            if character.isUppercase, !current.isEmpty {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words.contains { sensitiveWords.contains($0) }
    }

    private func hasArgument(_ label: String, in attribute: AttributeSyntax) -> Bool {
        guard let args = attribute.arguments?.as(LabeledExprListSyntax.self) else { return false }
        return args.contains { $0.label?.text == label }
    }

    /// `visibility: .internal` keeps a property from Siri and Shortcuts.
    private func isInternal(_ attribute: AttributeSyntax) -> Bool {
        guard let args = attribute.arguments?.as(LabeledExprListSyntax.self) else { return false }
        return args.contains {
            $0.label?.text == "visibility"
                && $0.expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "internal"
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
            // Apple: a widget-configuration intent is not a tool, and an intent that performs
            // no custom action has nothing for Siri to run.
            if !intent.hasAssistantIntent && !intent.isWidgetConfiguration && intent.hasPerform {
                let finding = Diagnostic(
                    severity: .warning,
                    message: "AppIntent '\(intent.name)' has no route to Siri: no system schema and no tool trait.",
                    filePath: fileName,
                    lineNumber: intent.line,
                    columnNumber: intent.column,
                    ruleId: "appintent-no-assistant-schema",
                    suggestedFix: "Add @AppIntent(.tool) to make this custom action available to Siri, or "
                        + "@AppIntent(schema:) if a system schema fits it (use @AppIntent(.tool, schema:) for "
                        + "a Shortcuts-only domain). To decline Siri on purpose, write "
                        + "`// appintents:exempt siri — <why>` above the intent."
                )
                if !declined("siri", intent: intent, finding: finding, into: &diagnostics) {
                    diagnostics.append(finding)
                }
            }
            if intent.isTool, intent.isHiddenFromShortcuts {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Intent '\(intent.name)' is a Siri tool but isDiscoverable is false, so Shortcuts "
                        + "cannot see it. Legal, and sometimes intended; this makes it visible.",
                    filePath: fileName,
                    lineNumber: intent.line,
                    columnNumber: intent.column,
                    ruleId: "appintent-hidden-tool",
                    suggestedFix: "Remove isDiscoverable = false to offer it to Shortcuts, or drop the .tool trait "
                        + "if Siri should not call it."
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
            if !entity.hasAuthenticationPolicy {
                for property in entity.sensitiveProperties {
                    let finding = Diagnostic(
                        severity: .warning,
                        message: "Property '\(property.name)' of AppEntity '\(entity.name)' is named like sensitive "
                            + "data but has no IntentAuthenticationPolicy.",
                        filePath: fileName,
                        lineNumber: property.line,
                        columnNumber: property.column,
                        ruleId: "appintent-sensitive-no-auth",
                        suggestedFix: "Add authenticationPolicy: to the property, or a static authenticationPolicy "
                            + "to the entity. If the name misleads, say so: "
                            + "`// appintents:exempt auth — <why this is not sensitive>`.")
                    if !declined(
                        "auth", lines: [property.line, property.line - 1], finding: finding,
                        subject: "property", into: &diagnostics) {
                        diagnostics.append(finding)
                    }
                }
            }
            for property in entity.undescribedProperties {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Property '\(property.name)' of AppEntity '\(entity.name)' has no description. "
                        + "Siri reads it to decide what the property means.",
                    filePath: fileName,
                    lineNumber: property.line,
                    columnNumber: property.column,
                    ruleId: "appintent-property-no-description",
                    suggestedFix: "Add description: to the attribute, e.g. "
                        + "@Property(title: \"\(property.name.capitalized)\", description: \"What it holds, in a sentence\"). "
                        + "A property Siri should not see takes visibility: .internal instead."
                ))
            }
            if !entity.hasAssistantEntity {
                diagnostics.append(Diagnostic(
                    severity: .note,
                    message: "AppEntity '\(entity.name)' adopts no system schema. Optional: a schema, where one fits, tells "
                        + "Siri and Shortcuts what the type is; a custom entity reaches Siri through its descriptions and Spotlight.",
                    filePath: fileName,
                    lineNumber: entity.line,
                    columnNumber: entity.column,
                    ruleId: "appintent-entity-not-assistant",
                    suggestedFix: "If a system schema fits this type, add @AppEntity(schema:)."
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
                    severity: .note,
                    message: "AppEnum '\(appEnum.name)' adopts no system schema. Optional: a schema, where one fits, tells "
                        + "Siri and Shortcuts what the type is.",
                    filePath: fileName,
                    lineNumber: appEnum.line,
                    columnNumber: appEnum.column,
                    ruleId: "appintent-enum-not-assistant",
                    suggestedFix: "If a system schema fits this enum, add @AppEnum(schema:)."
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

    // MARK: - Exposure exemptions

    /// Whether `intent` has declined `surface` with a reason, recording it if so.
    ///
    /// The marker may sit on the declaration's first line (attributes included), the line above
    /// it, or the line the type's name is on. A marker for a different surface does not count,
    /// one with no reason does not count and is reported, and an unknown surface is reported.
    private func declined(
        _ surface: String, intent: ExtractedIntent, finding: Diagnostic, into diagnostics: inout [Diagnostic]
    ) -> Bool {
        declined(
            surface, lines: [intent.declarationLine, intent.declarationLine - 1, intent.line],
            finding: finding, subject: "intent", into: &diagnostics)
    }

    /// The same decline, read from whichever of `lines` carries a marker.
    private func declined(
        _ surface: String, lines: [Int], finding: Diagnostic, subject: String, into diagnostics: inout [Diagnostic]
    ) -> Bool {
        let candidates = Set(lines).filter { $0 >= 1 && $0 <= sourceLines.count }.sorted()
        for lineNumber in candidates {
            let text = sourceLines[lineNumber - 1]
            guard let range = text.range(of: Self.exemptPrefix) else { continue }
            let tail = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let word = String(tail.prefix { $0.isLetter })
            guard Self.surfaces.contains(word) else {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "`\(Self.exemptPrefix) \(word)` names no surface. Use one of: siri, shortcuts, mcp, auth.",
                    filePath: fileName, lineNumber: lineNumber, columnNumber: 1,
                    ruleId: "appintent.exempt-unknown-surface",
                    suggestedFix: "Write `// \(Self.exemptPrefix) siri — <why>`."))
                continue
            }
            guard word == surface else { continue }
            let form = "\(Self.exemptPrefix) \(word)"
            let reason = InlineMarker.reason(in: text, after: form)
            guard reason.contains(where: { $0.isLetter || $0.isNumber }) else {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "`\(form)` states no reason. A marker that costs nothing to write cannot be "
                        + "told apart from a considered decision.",
                    filePath: fileName, lineNumber: lineNumber, columnNumber: 1,
                    ruleId: "appintent.exempt-no-justification",
                    suggestedFix: "Say why this \(subject) declines \(surface), e.g. "
                        + "`// \(form) — <the reason>`."))
                return false
            }
            overrides.append(.inlineMarker(
                form: form, ruleId: finding.ruleId ?? "appintent-no-assistant-schema", filePath: fileName,
                findingLine: finding.lineNumber, markerLine: lineNumber, comment: text))
            return true
        }
        return false
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
