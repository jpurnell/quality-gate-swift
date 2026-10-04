import SwiftSyntax

/// The `let` a name refers to, found lexically within one file.
///
/// `security.hardcoded-key` and `security.static-iv` treat a name bound by a `let` to a literal
/// as the literal (`ACipherIsItsArguments.md` §3). Matching names across the whole file would
/// make a parameter called `key` the file-scope constant called `key`; this walks outward from
/// the use instead, and stops at the first scope that binds the name — a parameter, a closure
/// argument, a loop variable, an `if let` / `guard let`, or a `var`, any of which means the value
/// is not known to be the literal.
///
/// Reaches: a local `let` above the use; a `let` or `static let` member of an enclosing type,
/// bare or through `self.` / `Self.`; a member of a type named in this file (`Keys.master`); and a
/// file-scope `let`. Nothing in another file.
enum LetResolver {

    /// One resolved binding.
    struct Binding {
        /// The bound name.
        let name: String
        /// The identity of the binding's pattern, so a rule can say which declaration it used.
        let pattern: SyntaxIdentifier
        /// The initialiser.
        let value: ExprSyntax
        /// True for a `static` / `class` member or a file-scope `let`: one value for the process.
        let isHeld: Bool
    }

    /// What one scope says about a name.
    private enum Lookup {
        case absent
        case shadowed
        case bound(Binding)
    }

    /// The binding `expression` names, if it is a bare name, `self.name`, `Self.name` or
    /// `TypeName.name` and resolves to a `let` with an initialiser.
    static func binding(for expression: ExprSyntax) -> Binding? {
        if let reference = expression.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil {
            return lexical(reference.baseName.text, from: Syntax(reference))
        }
        guard let member = expression.as(MemberAccessExprSyntax.self),
              let base = member.base?.as(DeclReferenceExprSyntax.self) else { return nil }
        let name = member.declName.baseName.text
        let baseName = base.baseName.text
        if baseName == "self" || baseName == "Self" {
            guard let members = enclosingMembers(of: Syntax(member)),
                  case .bound(let binding) = lookup(name, inMembers: members) else { return nil }
            return binding
        }
        guard baseName.first?.isUppercase == true else { return nil }
        let finder = TypeMemberFinder(typeName: baseName)
        finder.walk(member.root)
        for members in finder.memberLists {
            if case .bound(let binding) = lookup(name, inMembers: members) { return binding }
        }
        return nil
    }

    // MARK: - Lexical walk

    private static func lexical(_ name: String, from start: Syntax) -> Binding? {
        var child = start
        var current = start.parent
        while let node = current {
            if introducesBinding(named: name, node) { return nil }
            var result = Lookup.absent
            if let items = node.as(CodeBlockItemListSyntax.self) {
                let fileScope = items.parent?.is(SourceFileSyntax.self) == true
                // Inside a body only what came before counts; at file scope a global is visible
                // everywhere.
                result = lookup(name, inItems: items, before: fileScope ? nil : child.position, held: fileScope)
            } else if let members = node.as(MemberBlockItemListSyntax.self) {
                result = lookup(name, inMembers: members)
            }
            switch result {
            case .bound(let binding): return binding
            case .shadowed: return nil
            case .absent: break
            }
            child = node
            current = node.parent
        }
        return nil
    }

    private static func lookup(
        _ name: String,
        inItems items: CodeBlockItemListSyntax,
        before limit: AbsolutePosition?,
        held: Bool
    ) -> Lookup {
        var result = Lookup.absent
        for item in items {
            if let limit, item.position >= limit { break }
            if let declaration = item.item.as(VariableDeclSyntax.self),
               let found = lookup(name, in: declaration, held: held) {
                result = found
            } else if let guardStatement = item.item.as(GuardStmtSyntax.self),
                      conditions(guardStatement.conditions, bind: name) {
                result = .shadowed
            }
        }
        return result
    }

    private static func lookup(_ name: String, inMembers members: MemberBlockItemListSyntax) -> Lookup {
        for member in members {
            guard let declaration = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isStatic = declaration.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            if let found = lookup(name, in: declaration, held: isStatic) { return found }
        }
        return .absent
    }

    /// `.bound` for `let name = value`; `.shadowed` for a `var`, or a `let` with no initialiser.
    private static func lookup(_ name: String, in declaration: VariableDeclSyntax, held: Bool) -> Lookup? {
        for binding in declaration.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  pattern.identifier.text == name else { continue }
            guard declaration.bindingSpecifier.tokenKind == .keyword(.let),
                  let value = binding.initializer?.value else { return .shadowed }
            return .bound(Binding(name: name, pattern: pattern.id, value: value, isHeld: held))
        }
        return nil
    }

    /// Whether `node` binds `name` for everything beneath it: a parameter, a closure argument,
    /// a loop variable, or an `if let` / `while let`.
    private static func introducesBinding(named name: String, _ node: Syntax) -> Bool {
        if let function = node.as(FunctionDeclSyntax.self) {
            return function.signature.parameterClause.parameters.contains { parameterName($0) == name }
        }
        if let initialiser = node.as(InitializerDeclSyntax.self) {
            return initialiser.signature.parameterClause.parameters.contains { parameterName($0) == name }
        }
        if let subscriptDecl = node.as(SubscriptDeclSyntax.self) {
            return subscriptDecl.parameterClause.parameters.contains { parameterName($0) == name }
        }
        if let closure = node.as(ClosureExprSyntax.self), let clause = closure.signature?.parameterClause {
            switch clause {
            case .simpleInput(let shorthand):
                return shorthand.contains { $0.name.text == name }
            case .parameterClause(let parameters):
                return parameters.parameters.contains { ($0.secondName ?? $0.firstName).text == name }
            }
        }
        if let loop = node.as(ForStmtSyntax.self) {
            return SecurityVisitor.binds(loop.pattern, name)
        }
        if let conditional = node.as(IfExprSyntax.self) {
            return conditions(conditional.conditions, bind: name)
        }
        if let loop = node.as(WhileStmtSyntax.self) {
            return conditions(loop.conditions, bind: name)
        }
        return false
    }

    private static func parameterName(_ parameter: FunctionParameterSyntax) -> String {
        (parameter.secondName ?? parameter.firstName).text
    }

    private static func conditions(_ conditions: ConditionElementListSyntax, bind name: String) -> Bool {
        conditions.contains { element in
            guard let binding = element.condition.as(OptionalBindingConditionSyntax.self) else { return false }
            return SecurityVisitor.binds(binding.pattern, name)
        }
    }

    private static func enclosingMembers(of node: Syntax) -> MemberBlockItemListSyntax? {
        var current = node.parent
        while let candidate = current {
            if let members = candidate.as(MemberBlockItemListSyntax.self) { return members }
            current = candidate.parent
        }
        return nil
    }
}

/// Every member list of a type, or an extension of it, with a given name.
private final class TypeMemberFinder: SyntaxVisitor {
    let typeName: String
    private(set) var memberLists: [MemberBlockItemListSyntax] = []

    init(typeName: String) {
        self.typeName = typeName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.memberBlock)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.memberBlock)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.memberBlock)
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.name.text, node.memberBlock)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node.extendedType.trimmedDescription, node.memberBlock)
    }

    private func record(_ name: String, _ block: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
        if name == typeName { memberLists.append(block.members) }
        return .visitChildren
    }
}
