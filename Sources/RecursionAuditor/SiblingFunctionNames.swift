import SwiftSyntax

/// The function names declared alongside `node` in its enclosing type.
///
/// A call `name()` inside a property named `name` resolves to the method, not to the
/// property: a property is callable only when its own type is a function type, and in
/// that case no sibling method of the name exists to collide with it.
func siblingFunctionNames(of node: some SyntaxProtocol) -> Set<String> {
    var current = Syntax(node).parent
    while let candidate = current {
        if let members = candidate.as(MemberBlockSyntax.self) {
            var names: Set<String> = []
            for member in members.members {
                if let function = member.decl.as(FunctionDeclSyntax.self) {
                    names.insert(function.name.text)
                }
            }
            return names
        }
        current = candidate.parent
    }
    return []
}
