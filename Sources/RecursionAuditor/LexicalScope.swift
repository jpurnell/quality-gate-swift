import Foundation
import SwiftSyntax

/// The lexical declarations visible at a point in a syntax walk.
///
/// SwiftSyntax provides syntax, not binding: it knows `return sql` is a
/// `DeclReferenceExprSyntax` named `sql`, and cannot know whether that resolves to
/// the enclosing property or to a local declared two lines earlier. This stack is
/// the smallest thing that answers that question for the lexical cases — the ones a
/// syntactic pass can decide without a type checker.
///
/// Declarations are recorded as the walk encounters them, so ordering falls out of
/// the traversal: a local declared *after* a reference does not shadow it, which is
/// how Swift reads and the direction in which a mistake would become a false
/// negative rather than a false positive.
///
/// Semantic resolution — typealiases, protocol witnesses, generic constraints —
/// stays in the index-backed pass, which degrades honestly when no index exists.
/// See `quality-gate-swift-project/plans/proposals/RecursionNeedsScopeTracking.md`.
struct LexicalScope {
    /// One frame per enclosing block, closure, or case body.
    private var frames: [Set<String>] = [[]]

    /// Enters a nested scope.
    mutating func push() {
        frames.append([])
    }

    /// Leaves the innermost scope, discarding its declarations.
    ///
    /// Popping the root frame would leave the stack unusable, so it is refused
    /// rather than trapped: an unbalanced walk should degrade to "nothing is
    /// shadowed", which reports, rather than crash the checker.
    mutating func pop() {
        guard frames.count > 1 else { return }
        frames.removeLast()
    }

    /// Records a name as bound in the innermost scope.
    mutating func declare(_ name: String) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].insert(name)
    }

    /// True if any enclosing scope binds `name`.
    func shadows(_ name: String) -> Bool {
        frames.contains { $0.contains(name) }
    }
}


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
