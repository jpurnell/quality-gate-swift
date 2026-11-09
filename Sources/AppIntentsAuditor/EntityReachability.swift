import Foundation
import SwiftSyntax
import SwiftParser
import QualityGateCore

/// The two rules that need every file at once.
///
/// An entity's conformances, its query and the intents that use it are rarely declared together,
/// so neither rule can be answered from one file. This pass reads each file for facts, merges
/// them, and answers from the merge. It is syntactic: it follows names, not types, so an entity
/// reached through a generic or a typealias it cannot see is reported, and both rules are notes
/// for that reason.
///
/// - `appintent-entity-not-findable`: an `AppEntity` that is neither an `IndexedEntity` nor
///   served by an `EnumerableEntityQuery`. Siri finds entities through Spotlight or by listing
///   them; an entity that is neither can be passed in but not looked up.
/// - `appintent-entity-not-transferable`: an entity that a tool intent takes or returns, with
///   no `Transferable` conformance, so Siri cannot hand it to another app or tool.
///
/// Neither is an error, and neither has a decline marker yet. An entity left out of Spotlight is
/// a legitimate decision (a vault of private documents makes it on purpose), and notes do not
/// fail `--strict`. A marker belongs here when one of them is promoted to a warning.
enum EntityReachability {

    /// Analyses `sources`, keyed by file path. Files without `import AppIntents` are skipped.
    static func analyze(sources: [String: String]) -> [Diagnostic] {
        var facts = Facts()
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) where source.contains("import AppIntents") {
            let tree = Parser.parse(source: source)
            let converter = SourceLocationConverter(fileName: path, tree: tree)
            let collector = Collector(path: path, converter: converter)
            collector.walk(tree)
            facts.merge(collector.facts)
        }
        return facts.diagnostics()
    }
}

private struct EntityFact {
    let name: String
    let path: String
    let line: Int
    let column: Int
    var defaultQuery: String?
}

private struct ToolFact {
    let name: String
    /// Every identifier its parameters' types and `perform()` result mention.
    var usedTypes: Set<String> = []
}

private struct Facts {
    var entities: [EntityFact] = []
    var tools: [ToolFact] = []
    /// What each type or protocol declares or is extended to conform to.
    var conformances: [String: Set<String>] = [:]
    /// The entities each query type serves, by `typealias Entity` or the `allEntities()` result.
    var served: [String: Set<String>] = [:]

    mutating func merge(_ other: Facts) {
        entities += other.entities
        tools += other.tools
        for (name, set) in other.conformances { conformances[name, default: []].formUnion(set) }
        for (name, set) in other.served { served[name, default: []].formUnion(set) }
    }

    /// Everything `name` conforms to, through protocols declared in the project.
    func closure(of name: String) -> Set<String> {
        var seen: Set<String> = []
        var pending = [name]
        while let next = pending.popLast() {
            for parent in conformances[next] ?? [] where seen.insert(parent).inserted { pending.append(parent) }
        }
        return seen
    }

    func diagnostics() -> [Diagnostic] {
        var out: [Diagnostic] = []
        let enumerableQueries = Set(served.keys.filter { closure(of: $0).contains("EnumerableEntityQuery") })
            .union(conformances.keys.filter { closure(of: $0).contains("EnumerableEntityQuery") })
        var enumerated: Set<String> = []
        for query in enumerableQueries { enumerated.formUnion(served[query] ?? []) }

        for entity in entities.sorted(by: { ($0.path, $0.line) < ($1.path, $1.line) }) {
            let adopted = closure(of: entity.name)
            let viaQuery = entity.defaultQuery.map { enumerableQueries.contains($0) } ?? false
            if !adopted.contains("IndexedEntity"), !enumerated.contains(entity.name), !viaQuery {
                out.append(Diagnostic(
                    severity: .note,
                    message: "Entity '\(entity.name)' is neither an IndexedEntity nor served by an "
                        + "EnumerableEntityQuery, so Siri has no way to look it up.",
                    filePath: entity.path, lineNumber: entity.line, columnNumber: entity.column,
                    ruleId: "appintent-entity-not-findable",
                    suggestedFix: "Conform it to IndexedEntity, or give its query EnumerableEntityQuery. "
                        + "Leaving it out of Spotlight can be right; this is a note for that reason."))
            }

            let users = tools.filter { $0.usedTypes.contains(entity.name) }.map(\.name).sorted()
            if !users.isEmpty, !adopted.contains("Transferable") {
                let names = users.map { "'\($0)'" }.joined(separator: ", ")
                out.append(Diagnostic(
                    severity: .note,
                    message: "Entity '\(entity.name)' is used by tool intent \(names) but is not Transferable, "
                        + "so Siri cannot pass it to another app or tool.",
                    filePath: entity.path, lineNumber: entity.line, columnNumber: entity.column,
                    ruleId: "appintent-entity-not-transferable",
                    suggestedFix: "Conform '\(entity.name)' to Transferable with a transfer representation."))
            }
        }
        return out
    }
}

private final class Collector: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    var facts = Facts()

    /// The declaration being read, so a member can be attributed to it.
    private var typeStack: [String] = []
    private var toolIndex: [Int?] = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func enter(_ name: String, inheritance: InheritanceClauseSyntax?) {
        facts.conformances[name, default: []].formUnion(AppIntentSyntax.inheritedTypeNames(inheritance))
        typeStack.append(name)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let inheritance = AppIntentSyntax.inheritedTypeNames(node.inheritanceClause)
        enter(name, inheritance: node.inheritanceClause)
        if inheritance.contains("AppEntity") {
            let loc = node.name.startLocation(converter: converter)
            facts.entities.append(EntityFact(name: name, path: path, line: loc.line, column: loc.column))
        }
        if inheritance.contains("AppIntent"),
           AppIntentSyntax.hasToolTrait(node.attributes) || inheritance.contains("ToolIntent") {
            facts.tools.append(ToolFact(name: name))
            toolIndex.append(facts.tools.count - 1)
        } else {
            toolIndex.append(nil)
        }
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { leave() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.name.text, inheritance: node.inheritanceClause)
        toolIndex.append(nil)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { leave() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.name.text, inheritance: node.inheritanceClause)
        toolIndex.append(nil)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { leave() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node.name.text, inheritance: node.inheritanceClause)
        toolIndex.append(nil)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) { leave() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.extendedType.as(IdentifierTypeSyntax.self)?.name.text ?? ""
        enter(name, inheritance: node.inheritanceClause)
        toolIndex.append(nil)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { leave() }

    private func leave() {
        _ = typeStack.popLast()
        _ = toolIndex.popLast()
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == "Entity", let owner = typeStack.last {
            facts.served[owner, default: []].formUnion(AppIntentSyntax.identifiers(in: node.initializer.value))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let owner = typeStack.last, let result = node.signature.returnClause?.type else { return .visitChildren }
        switch node.name.text {
        case "allEntities":
            facts.served[owner, default: []].formUnion(AppIntentSyntax.identifiers(in: result))
        case "perform":
            if let index = toolIndex.last ?? nil {
                facts.tools[index].usedTypes.formUnion(AppIntentSyntax.identifiers(in: result))
            }
        default:
            break
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let binding = node.bindings.first,
              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }

        if name == "defaultQuery", let owner = typeStack.last,
           let index = facts.entities.lastIndex(where: { $0.name == owner }) {
            if let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                facts.entities[index].defaultQuery = callee.baseName.text
            } else if let type = binding.typeAnnotation?.type {
                facts.entities[index].defaultQuery = AppIntentSyntax.identifiers(in: type).first
            }
        }

        let isParameter = node.attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Parameter"
        }
        if isParameter, let index = toolIndex.last ?? nil, let type = binding.typeAnnotation?.type {
            facts.tools[index].usedTypes.formUnion(AppIntentSyntax.identifiers(in: type))
        }
        return .visitChildren
    }
}
