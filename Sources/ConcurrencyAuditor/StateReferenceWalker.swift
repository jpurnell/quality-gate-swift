import SwiftSyntax
import SyntaxScope

/// Decides whether a body of code touches the enclosing instance's state: a member
/// reached through `self`, or a stored property named bare, through implicit `self`.
///
/// A bare name is the property only when nothing nearer binds it. Swift resolves an
/// unqualified name to the innermost lexical binding before it tries implicit `self`,
/// so a capture-list entry, a parameter, a local, or an `if let` / `guard let` / `for` /
/// `case let` binding of the same spelling is that binding, not the property. The
/// walker carries a ``LexicalScope`` to tell them apart, seeded by the caller with
/// whatever was bound outside the body (``visibleBindings(at:)``).
///
/// A member name is never a reference by name: in `peer.device` the walk visits
/// `peer` and not `device`. Through a self-shaped base (``isSelfReference(_:)``) the
/// member is the instance's whatever locals are in scope, so the scope does not apply
/// on that branch.
///
/// See `quality-gate-swift-project/plans/proposals/AShadowIsNotTheProperty.md`.
final class StateReferenceWalker: SyntaxVisitor {
    /// Which members reached through `self` count as touching state.
    enum SelfMembers {
        /// Any member at all — `self.count`, `self.bump()`. The Task rule: a deferred
        /// synchronous call on `self` is the same hazard as a deferred write.
        case all
        /// Only the stored properties in `names`. The deinit rule: calling a method is
        /// the compiler's to judge; reading isolated storage is this rule's.
        case storedProperties
    }

    private let names: Set<String>
    private let selfMembers: SelfMembers
    /// Whether `await` subtrees and nested `Task` calls are left unexamined: an awaited
    /// expression is a hop, and a nested Task is reported at its own visit.
    private let skipsHopsAndNestedTasks: Bool
    private var scope: LexicalScope
    private(set) var found = false

    init(
        storedProperties names: Set<String>,
        boundOutside: Set<String>,
        selfMembers: SelfMembers,
        skipsHopsAndNestedTasks: Bool
    ) {
        self.names = names
        self.selfMembers = selfMembers
        self.skipsHopsAndNestedTasks = skipsHopsAndNestedTasks
        self.scope = LexicalScope(binding: boundOutside)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: Skipped subtrees

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        skipsHopsAndNestedTasks ? .skipChildren : .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if skipsHopsAndNestedTasks,
           let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
           callee.baseName.text == "Task" {
            return .skipChildren
        }
        return .visitChildren
    }

    /// A key path component names a member of the key path's root type.
    override func visit(_ node: KeyPathPropertyComponentSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    /// Everything under `let` / `var` in a pattern is a binding, not a reference.
    /// `case let .some(device)` parses its bindings as `DeclReferenceExpr`s, and reading
    /// them as references would report the very name being bound.
    override func visit(_ node: ValueBindingPatternSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    // MARK: Scopes

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        scope.push()
        return .visitChildren
    }
    override func visitPost(_ node: CodeBlockSyntax) { scope.pop() }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        scope.push()
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { scope.pop() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        scope.push()
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { scope.pop() }

    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        scope.push()
        return .visitChildren
    }
    override func visitPost(_ node: SwitchCaseSyntax) { scope.pop() }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        scope.push()
        return .visitChildren
    }
    override func visitPost(_ node: WhileStmtSyntax) { scope.pop() }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        scope.push()
        for name in boundNames(of: node) { scope.declare(name) }
        return .visitChildren
    }
    override func visitPost(_ node: CatchClauseSyntax) { scope.pop() }

    /// The condition bindings of an `if` are visible in its body and not in its `else`.
    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        scope.push()
        walk(node.conditions)
        walk(node.body)
        scope.pop()
        if let elseBody = node.elseBody { walk(elseBody) }
        return .skipChildren
    }

    /// The loop pattern is bound for the body only: in `for x in x` the sequence is the
    /// outer `x`.
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        walk(node.sequence)
        scope.push()
        for name in bindingNames(inMatching: node.pattern) { scope.declare(name) }
        if let whereClause = node.whereClause { walk(whereClause) }
        walk(node.body)
        scope.pop()
        return .skipChildren
    }

    // MARK: Declarations
    //
    // Recorded in `visitPost` so the initializer is walked first: in `let x = x` the
    // right-hand `x` is the outer one, and a read before a later `let` of the same name
    // still resolves outward. Declaring on the way out is what keeps lexical order.

    override func visitPost(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            for name in boundNames(in: binding.pattern) { scope.declare(name) }
        }
    }

    /// Shorthand `if let device` has no initializer to walk, but it reads `device`:
    /// the property, unless something nearer binds the name.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if node.initializer == nil,
           let pattern = node.pattern.as(IdentifierPatternSyntax.self) {
            noteBareReference(to: pattern.identifier.text)
        }
        return .visitChildren
    }
    override func visitPost(_ node: OptionalBindingConditionSyntax) {
        for name in boundNames(in: node.pattern) { scope.declare(name) }
    }

    override func visitPost(_ node: MatchingPatternConditionSyntax) {
        for name in bindingNames(inMatching: node.pattern) { scope.declare(name) }
    }

    override func visitPost(_ node: SwitchCaseLabelSyntax) {
        for item in node.caseItems {
            for name in bindingNames(inMatching: item.pattern) { scope.declare(name) }
        }
    }

    /// A capture's initializer is read when the closure is created, in the scope
    /// outside it, so the name is declared only after the expression has been walked.
    override func visitPost(_ node: ClosureCaptureSyntax) {
        if let name = boundName(of: node) { scope.declare(name) }
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        scope.declare((node.secondName ?? node.firstName).text)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        scope.declare(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        scope.declare((node.secondName ?? node.firstName).text)
        return .visitChildren
    }

    // MARK: References

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard let base = node.base else { return .visitChildren }
        // `Self.x` is static storage, never the instance's.
        if let reference = base.as(DeclReferenceExprSyntax.self),
           reference.baseName.tokenKind == .keyword(.Self) {
            return .skipChildren
        }
        guard isSelfReference(base) else { return .visitChildren }
        // `self.name` names the member whatever locals are in scope, so the shadow
        // stack deliberately does not apply on this branch.
        switch selfMembers {
        case .all:
            found = true
        case .storedProperties:
            if names.contains(node.declName.baseName.text) { found = true }
        }
        return .skipChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // `other.name` — the member belongs to `other`. The self-shaped case was
        // decided by the member-access override and never reaches here.
        if let member = node.parent?.as(MemberAccessExprSyntax.self),
           member.declName.id == node.id {
            return .skipChildren
        }
        noteBareReference(to: node.baseName.text)
        return .skipChildren
    }

    /// A bare name is the stored property when nothing nearer binds it.
    private func noteBareReference(to name: String) {
        guard names.contains(name), !scope.shadows(name) else { return }
        found = true
    }
}
