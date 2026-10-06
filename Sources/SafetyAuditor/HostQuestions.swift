import ExternalInputSyntax
import Foundation
import SwiftSyntax

// MARK: - Host questions in one function

/// What one function asks about hosts, and what it hands URLs to for checking.
struct HostFacts {
    struct Question {
        /// The URL the question is about, by the name it goes by.
        let root: String
        let position: AbsolutePosition
    }

    struct Check {
        let root: String
        let slot: RequestSlot
        let position: AbsolutePosition
    }

    var questions: [Question] = []
    var checks: [Check] = []
}

/// Reads ``HostFacts`` off a function body (§3.5).
///
/// A **question** is the host compared with something that is not `nil`, tested for membership
/// or a prefix or suffix, switched on, or handed to a function inside a condition. Asking
/// whether there *is* a host — `!= nil`, `isEmpty` — is not one.
final class HostQuestionReader: SyntaxVisitor {
    private let aliases: [String: String]
    private let body: SyntaxIdentifier
    private let calleeName: (FunctionCallExprSyntax) -> String?
    private(set) var questions: [HostFacts.Question] = []
    private(set) var checks: [HostFacts.Check] = []

    init(aliases: [String: String], body: SyntaxIdentifier, calleeName: @escaping (FunctionCallExprSyntax) -> String?) {
        self.aliases = aliases
        self.body = body
        self.calleeName = calleeName
        super.init(viewMode: .sourceAccurate)
    }

    // A nested function asks its own questions.
    private func enter(_ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        node.id == body ? .visitChildren : .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(node) }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "host", let base = node.base,
           let root = RequestFlowCollector.rootName(of: base), Self.isQuestion(about: Syntax(node)) {
            questions.append(.init(root: root, position: node.position))
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if let root = aliases[node.baseName.text], Self.isQuestion(about: Syntax(node)) {
            questions.append(.init(root: root, position: node.position))
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard Self.isInCondition(Syntax(node)) || Self.isTryStatement(Syntax(node)),
              let callee = calleeName(node) else { return .visitChildren }
        for (index, argument) in node.arguments.enumerated() {
            guard let root = RequestFlowCollector.unwrapped(argument.expression).as(DeclReferenceExprSyntax.self)?
                .baseName.text else { continue }
            checks.append(.init(
                root: root, slot: RequestSlot(function: callee, label: argument.label?.text ?? "_\(index)"),
                position: node.position))
        }
        return .visitChildren
    }

    /// Whether the host at `reference` is being asked about, rather than read or tested for presence.
    static func isQuestion(about reference: Syntax) -> Bool {
        var current = reference
        // Bounded climb through what leaves the value the host: `?`, `!`, `()`, `.lowercased()`.
        for _ in 0..<12 {
            guard let parent = current.parent else { return false }
            if parent.is(OptionalChainingExprSyntax.self) || parent.is(ForceUnwrapExprSyntax.self)
                || parent.is(PrefixOperatorExprSyntax.self) {
                current = parent
            } else if let member = parent.as(MemberAccessExprSyntax.self), member.base?.id == current.id {
                let name = member.declName.baseName.text
                if RequestFlowCollector.comparisons.contains(name) { return true }
                guard RequestFlowCollector.hostTransforms.contains(name) else { return false }
                current = parent
            } else if let call = parent.as(FunctionCallExprSyntax.self), call.calledExpression.id == current.id {
                current = parent
            } else if parent.is(ExprListSyntax.self), let sequence = parent.parent?.as(SequenceExprSyntax.self) {
                switch comparison(of: current, in: sequence) {
                case .compared: return true
                case .presence: return false
                case .coalesced: current = Syntax(sequence)
                case .other: return false
                }
            } else if let argument = parent.as(LabeledExprSyntax.self) {
                guard let list = argument.parent, let owner = list.parent else { return false }
                if let tuple = owner.as(TupleExprSyntax.self), tuple.elements.count == 1 {
                    current = owner
                } else if let call = owner.as(FunctionCallExprSyntax.self) {
                    let method = call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                    return method.map(RequestFlowCollector.comparisons.contains) == true || isInCondition(Syntax(call))
                } else {
                    return false
                }
            } else if let switched = parent.as(SwitchExprSyntax.self) {
                return switched.subject.id == current.id
            } else {
                return false
            }
        }
        return false
    }

    private enum Comparison { case compared, presence, coalesced, other }
    private static let equalityOperators: Set<String> = ["==", "!=", "~="]

    /// How `operand` is used in an unfolded operator sequence.
    private static func comparison(of operand: Syntax, in sequence: SequenceExprSyntax) -> Comparison {
        let elements = Array(sequence.elements)
        guard let index = elements.firstIndex(where: { $0.id == operand.id }) else { return .other }
        var coalesced = false
        for (operatorIndex, otherIndex) in [(index - 1, index - 2), (index + 1, index + 2)]
        where elements.indices.contains(operatorIndex) && elements.indices.contains(otherIndex) {
            guard let symbol = elements[operatorIndex].as(BinaryOperatorExprSyntax.self)?.operator.text else { continue }
            if Self.equalityOperators.contains(symbol) {
                return elements[otherIndex].is(NilLiteralExprSyntax.self) ? .presence : .compared
            }
            if symbol == "??" { coalesced = true }
        }
        return coalesced ? .coalesced : .other
    }

    /// Whether `node` is inside a `guard` / `if` / `while` condition of its own function.
    static func isInCondition(_ node: Syntax) -> Bool {
        var cursor = node.parent
        while let current = cursor {
            if current.is(ConditionElementSyntax.self) { return true }
            if current.is(CodeBlockItemSyntax.self) || current.is(ClosureExprSyntax.self) { return false }
            cursor = current.parent
        }
        return false
    }

    /// `try validate(url)` as a statement: it throws instead of returning false.
    static func isTryStatement(_ node: Syntax) -> Bool {
        var cursor = node.parent
        var sawTry = false
        while let current = cursor {
            if current.is(TryExprSyntax.self) {
                sawTry = true
            } else if current.is(CodeBlockItemSyntax.self) {
                return sawTry
            } else if !current.is(AwaitExprSyntax.self) {
                return false
            }
            cursor = current.parent
        }
        return false
    }
}
