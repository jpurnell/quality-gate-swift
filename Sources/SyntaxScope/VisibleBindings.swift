import SwiftSyntax

/// The local names in scope at `node`: every binding made lexically outside it that
/// code at `node` can see, up to the enclosing type.
///
/// The walk goes **up** from `node` and stops at the first `MemberBlockSyntax` or at
/// the source file, so the members of the enclosing type — the properties a caller is
/// usually trying to tell these names apart from — are never included.
///
/// | ancestor | contributes |
/// |---|---|
/// | statement list | `let` / `var` and `guard` bindings of the statements *before* the one on the path |
/// | `if`, `while` | their condition bindings, when the path runs through the body |
/// | `for` | the loop pattern, when the path runs through the body |
/// | `catch` | its patterns, or the implicit `error` |
/// | `switch` case | the case-item bindings |
/// | closure | its parameters and capture-list names |
/// | function, initializer, subscript | its parameters |
/// | accessor | its explicit parameter, or the implicit `newValue` / `oldValue` |
///
/// Only earlier statements of each enclosing list count, and only of that list: a
/// `let` inside a sibling block, or one declared after `node`, is not visible, which
/// is how Swift reads.
public func visibleBindings(at node: some SyntaxProtocol) -> Set<String> {
    var names: Set<String> = []
    var child = Syntax(node)
    while let parent = child.parent {
        if parent.is(MemberBlockSyntax.self) || parent.is(SourceFileSyntax.self) { break }
        names.formUnion(bindings(contributedBy: parent, toChild: child))
        child = parent
    }
    return names
}

/// What one ancestor binds for the child on the path below it.
private func bindings(contributedBy parent: Syntax, toChild child: Syntax) -> [String] {
    if let list = parent.as(CodeBlockItemListSyntax.self) {
        return earlierBindings(in: list, before: child)
    }
    if let ifExpr = parent.as(IfExprSyntax.self) {
        return ifExpr.body.id == child.id ? boundNames(in: ifExpr.conditions) : []
    }
    if let whileStmt = parent.as(WhileStmtSyntax.self) {
        return whileStmt.body.id == child.id ? boundNames(in: whileStmt.conditions) : []
    }
    if let forStmt = parent.as(ForStmtSyntax.self) {
        return forStmt.body.id == child.id ? bindingNames(inMatching: forStmt.pattern) : []
    }
    if let catchClause = parent.as(CatchClauseSyntax.self) {
        guard catchClause.body.id == child.id else { return [] }
        return boundNames(of: catchClause)
    }
    if let switchCase = parent.as(SwitchCaseSyntax.self) {
        guard switchCase.statements.id == child.id else { return [] }
        return boundNames(of: switchCase)
    }
    if let closure = parent.as(ClosureExprSyntax.self) {
        return closure.statements.id == child.id ? boundNames(of: closure) : []
    }
    if let function = parent.as(FunctionDeclSyntax.self) {
        return boundNames(in: function.signature.parameterClause.parameters)
    }
    if let initializer = parent.as(InitializerDeclSyntax.self) {
        return boundNames(in: initializer.signature.parameterClause.parameters)
    }
    if let subscriptDecl = parent.as(SubscriptDeclSyntax.self) {
        return boundNames(in: subscriptDecl.parameterClause.parameters)
    }
    if let accessor = parent.as(AccessorDeclSyntax.self) {
        return boundNames(of: accessor)
    }
    return []
}

/// The `let` / `var` and `guard` bindings of the statements that end before `child`.
private func earlierBindings(in list: CodeBlockItemListSyntax, before child: Syntax) -> [String] {
    var names: [String] = []
    for item in list {
        if item.id == child.id { break }
        if let variable = item.item.as(VariableDeclSyntax.self) {
            for binding in variable.bindings {
                names.append(contentsOf: boundNames(in: binding.pattern))
            }
        } else if let guardStmt = item.item.as(GuardStmtSyntax.self) {
            names.append(contentsOf: boundNames(in: guardStmt.conditions))
        }
    }
    return names
}

/// The names a `catch` clause binds: its patterns, or the implicit `error`.
public func boundNames(of clause: CatchClauseSyntax) -> [String] {
    guard !clause.catchItems.isEmpty else { return ["error"] }
    var names: [String] = []
    for item in clause.catchItems {
        if let pattern = item.pattern {
            names.append(contentsOf: bindingNames(inMatching: pattern))
        }
    }
    return names
}

/// The names a `switch` case binds in its body.
public func boundNames(of switchCase: SwitchCaseSyntax) -> [String] {
    guard case .case(let label) = switchCase.label else { return [] }
    var names: [String] = []
    for item in label.caseItems {
        names.append(contentsOf: bindingNames(inMatching: item.pattern))
    }
    return names
}

/// The name an accessor binds: its explicit parameter, or the implicit `newValue`
/// (`set`, `willSet`) or `oldValue` (`didSet`).
public func boundNames(of accessor: AccessorDeclSyntax) -> [String] {
    if let parameters = accessor.parameters {
        return [parameters.name.text]
    }
    switch accessor.accessorSpecifier.tokenKind {
    case .keyword(.set), .keyword(.willSet):
        return ["newValue"]
    case .keyword(.didSet):
        return ["oldValue"]
    default:
        return []
    }
}
