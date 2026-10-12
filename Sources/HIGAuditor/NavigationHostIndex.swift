import Foundation
import SwiftParser
import SwiftSyntax

/// Which declarations in a project host navigation.
///
/// `hig.navigation-pattern` recommends a sidebar where there is a navigation hierarchy. A
/// `NavigationStack` is not evidence of one: a sheet wraps its form in a stack to get a title
/// bar and a toolbar, and pushes nothing. So the rule asks whether the stack *hosts*
/// navigation — and the `NavigationLink` that answers it is as often in the row type, or in a
/// helper property declared in an extension in another file, as in the stack's own closure.
///
/// This is that answer, computed once over every SwiftUI file before any is audited:
///
/// - ``types`` — every type whose declaration, or any extension of it, names `NavigationLink`
///   or `navigationDestination`, or names another type that does. Followed to a fixed point,
///   so `Screen` → `Section` → `Row` → `NavigationLink` makes all three hosts.
/// - ``membersByType`` — for each type, the properties and functions that do the same, so a
///   stack whose content is `rows` is answered by what `rows` contains.
///
/// Everything is matched by identifier; nothing is type-checked. That over-approximates —
/// a type that merely mentions a hosting type is a host — and the direction is the safe one:
/// a stack is read as chrome only when nothing it names is known to push.
struct NavigationHostIndex: Sendable, Equatable {
    /// The identifiers that are navigation in themselves.
    static let markers: Set<String> = ["NavigationLink", "navigationDestination"]

    /// Types that host navigation, project-wide.
    var types: Set<String>
    /// For each type, the members that host navigation.
    var membersByType: [String: Set<String>]

    init(types: Set<String> = [], membersByType: [String: Set<String>] = [:]) {
        self.types = types
        self.membersByType = membersByType
    }

    /// The union of two indexes.
    func merging(_ other: NavigationHostIndex) -> NavigationHostIndex {
        var merged = self
        merged.types.formUnion(other.types)
        for (owner, members) in other.membersByType {
            merged.membersByType[owner, default: []].formUnion(members)
        }
        return merged
    }

    /// Builds the index from source text. Files that do not import SwiftUI are skipped.
    static func build(sources: [String]) -> NavigationHostIndex {
        build(
            trees: sources.filter { $0.contains("import SwiftUI") }.map { Parser.parse(source: $0) },
            seededWith: NavigationHostIndex())
    }

    /// Builds the index from parsed files, starting from hosts already known.
    static func build(trees: [SourceFileSyntax], seededWith seed: NavigationHostIndex) -> NavigationHostIndex {
        let collector = Collector(viewMode: .sourceAccurate)
        for tree in trees { collector.walk(tree) }

        // Types first, to a fixed point. Each pass can only add, and there are finitely many
        // types, so the bound is the number of them.
        var hosts = seed.types
        for _ in 0...collector.typeIdentifiers.count {
            var added = false
            for (name, identifiers) in collector.typeIdentifiers where !hosts.contains(name) {
                if !identifiers.isDisjoint(with: markers) || !identifiers.isDisjoint(with: hosts) {
                    hosts.insert(name)
                    added = true
                }
            }
            guard added else { break }
        }

        // Then members, each against the finished set of types and its own type's other
        // hosting members — `content` built from `rows` built from links.
        var membersByType = seed.membersByType
        for (owner, members) in collector.memberIdentifiers {
            var hosting = membersByType[owner] ?? []
            for _ in 0...members.count {
                var added = false
                for (name, identifiers) in members where !hosting.contains(name) {
                    if !identifiers.isDisjoint(with: markers) || !identifiers.isDisjoint(with: hosts)
                        || !identifiers.isDisjoint(with: hosting) {
                        hosting.insert(name)
                        added = true
                    }
                }
                guard added else { break }
            }
            if !hosting.isEmpty { membersByType[owner] = hosting }
        }

        return NavigationHostIndex(types: hosts, membersByType: membersByType)
    }

    /// The type a declaration node declares or extends, if it is one.
    static func declaredTypeName(_ node: Syntax) -> String? {
        if let declaration = node.as(StructDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(ClassDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(EnumDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(ActorDeclSyntax.self) { return declaration.name.text }
        if let declaration = node.as(ExtensionDeclSyntax.self) {
            return declaration.extendedType.trimmedDescription
        }
        return nil
    }

    /// Gathers, per type and per member, the identifiers its declaration contains.
    private final class Collector: SyntaxVisitor {
        private(set) var typeIdentifiers: [String: Set<String>] = [:]
        private(set) var memberIdentifiers: [String: [String: Set<String>]] = [:]
        private var enclosingTypes: [String] = []

        private func identifiers(in node: some SyntaxProtocol, excluding own: String) -> Set<String> {
            var found: Set<String> = []
            for token in node.tokens(viewMode: .sourceAccurate) {
                if case .identifier(let text) = token.tokenKind, text != own { found.insert(text) }
            }
            return found
        }

        private func enter(_ node: some SyntaxProtocol) {
            guard let name = NavigationHostIndex.declaredTypeName(Syntax(node)) else { return }
            typeIdentifiers[name, default: []].formUnion(identifiers(in: node, excluding: name))
            enclosingTypes.append(name)
        }

        private func leave(_ node: some SyntaxProtocol) {
            guard NavigationHostIndex.declaredTypeName(Syntax(node)) != nil else { return }
            enclosingTypes.removeLast()
        }

        private func record(member name: String, _ node: some SyntaxProtocol) {
            // `body` is the type itself, already answered by `typeIdentifiers`; nothing refers
            // to it by name from inside a stack.
            guard let owner = enclosingTypes.last, name != "body" else { return }
            memberIdentifiers[owner, default: [:]][name, default: []]
                .formUnion(identifiers(in: node, excluding: name))
        }

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(node); return .visitChildren }
        override func visitPost(_ node: StructDeclSyntax) { leave(node) }
        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(node); return .visitChildren }
        override func visitPost(_ node: ClassDeclSyntax) { leave(node) }
        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(node); return .visitChildren }
        override func visitPost(_ node: EnumDeclSyntax) { leave(node) }
        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node); return .visitChildren }
        override func visitPost(_ node: ActorDeclSyntax) { leave(node) }
        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { enter(node); return .visitChildren }
        override func visitPost(_ node: ExtensionDeclSyntax) { leave(node) }

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            for binding in node.bindings {
                if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                    record(member: pattern.identifier.text, binding)
                }
            }
            return .visitChildren
        }

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            record(member: node.name.text, node)
            return .visitChildren
        }
    }
}
