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
public struct LexicalScope: Sendable {
    /// One frame per enclosing block, closure, or case body.
    private var frames: [Set<String>]

    /// Creates a scope whose root frame already binds `names`.
    ///
    /// The seed is for bindings made outside the subtree about to be walked — a
    /// function's parameters, the locals above a closure — which the walk itself
    /// will never encounter. See ``visibleBindings(at:)``.
    public init(binding names: Set<String> = []) {
        frames = [names]
    }

    /// Enters a nested scope.
    public mutating func push() {
        frames.append([])
    }

    /// Leaves the innermost scope, discarding its declarations.
    ///
    /// Popping the root frame would leave the stack unusable, so it is refused
    /// rather than trapped: an unbalanced walk should degrade to "nothing is
    /// shadowed", which reports, rather than crash the checker.
    public mutating func pop() {
        guard frames.count > 1 else { return }
        frames.removeLast()
    }

    /// Records a name as bound in the innermost scope.
    public mutating func declare(_ name: String) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].insert(name)
    }

    /// True if any enclosing scope binds `name`.
    public func shadows(_ name: String) -> Bool {
        frames.contains { $0.contains(name) }
    }
}
