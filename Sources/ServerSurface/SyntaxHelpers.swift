import Foundation
import SwiftSyntax

/// Small readings of syntax the recognisers share.
enum SyntaxReading {

    /// The callee's last name component: `bind` for `bootstrap.bind(…)`, `NWListener` for
    /// `NWListener(…)`.
    static func calleeName(_ call: FunctionCallExprSyntax) -> String? {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        return nil
    }

    /// The receiver of a member call, when there is one.
    static func receiver(_ call: FunctionCallExprSyntax) -> ExprSyntax? {
        call.calledExpression.as(MemberAccessExprSyntax.self)?.base
    }

    /// The argument labelled `label`.
    static func argument(_ call: FunctionCallExprSyntax, labelled label: String) -> ExprSyntax? {
        call.arguments.first { $0.label?.text == label }?.expression
    }

    /// The value of a string literal with no interpolation.
    static func stringValue(_ expr: ExprSyntax?) -> String? {
        expr?.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }

    /// `expr` with any `try` and `await` taken off.
    static func unwrapped(_ expr: ExprSyntax) -> ExprSyntax {
        if let tryExpr = expr.as(TryExprSyntax.self) { return unwrappedOnce(tryExpr.expression) }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) { return unwrappedOnce(awaitExpr.expression) }
        return expr
    }

    /// One more layer — `try await` is two.
    private static func unwrappedOnce(_ expr: ExprSyntax) -> ExprSyntax {
        if let tryExpr = expr.as(TryExprSyntax.self) { return tryExpr.expression }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) { return awaitExpr.expression }
        return expr
    }

    /// The name of the type declaration `node` sits in: the struct, class, actor or enum, or the
    /// extended type of an extension.
    static func enclosingTypeName(_ node: some SyntaxProtocol) -> String? {
        var current = node.parent
        while let candidate = current {
            if let name = typeName(of: candidate) { return name }
            current = candidate.parent
        }
        return nil
    }

    /// The declared or extended type name of a declaration node, if it is one.
    static func typeName(of node: Syntax) -> String? {
        if let decl = node.as(StructDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ClassDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ActorDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(EnumDeclSyntax.self) { return decl.name.text }
        if let decl = node.as(ExtensionDeclSyntax.self) { return decl.extendedType.trimmedDescription }
        return nil
    }

    /// The nearest function, initialiser, accessor or closure body around `node`, or the file.
    static func enclosingBody(_ node: some SyntaxProtocol) -> Syntax {
        var current = node.parent
        var last = Syntax(node)
        while let candidate = current {
            if candidate.is(FunctionDeclSyntax.self) || candidate.is(InitializerDeclSyntax.self)
                || candidate.is(AccessorDeclSyntax.self) || candidate.is(ClosureExprSyntax.self) {
                return candidate
            }
            last = candidate
            current = candidate.parent
        }
        return last
    }

    /// The parameter's local name — the second name when there is one.
    static func parameterName(_ parameter: FunctionParameterSyntax) -> String {
        (parameter.secondName ?? parameter.firstName).text
    }

    /// Whether `literal` sits where it is compared against, listed, keyed or subscripted, rather
    /// than chosen. geo-audit's validator compares against `0.0.0.0` to reject it.
    static func isInertLiteral(_ literal: StringLiteralExprSyntax, within root: Syntax) -> Bool {
        var current = literal.parent
        while let node = current, node.id != root.id {
            if node.is(ArrayExprSyntax.self) || node.is(DictionaryExprSyntax.self)
                || node.is(SubscriptCallExprSyntax.self) || node.is(ExpressionSegmentSyntax.self) {
                return true
            }
            if let list = node.as(ExprListSyntax.self), containsComparison(list) { return true }
            if let call = node.as(FunctionCallExprSyntax.self), calleeName(call) != nil,
               node.id != root.id, isComparisonCall(call) {
                return true
            }
            current = node.parent
        }
        return false
    }

    private static func containsComparison(_ list: ExprListSyntax) -> Bool {
        list.contains { element in
            guard let op = element.as(BinaryOperatorExprSyntax.self) else { return false }
            return ServerSurfaceVocabulary.comparisonOperators.contains(op.operator.text)
        }
    }

    private static func isComparisonCall(_ call: FunctionCallExprSyntax) -> Bool {
        ["hasPrefix", "hasSuffix", "contains", "starts"].contains(calleeName(call) ?? "")
    }

    /// Host literals in `expr` that choose an address — not compared, listed or subscripted.
    static func chosenLiterals(in expr: ExprSyntax) -> [StringLiteralExprSyntax] {
        let collector = LiteralCollector(viewMode: .sourceAccurate)
        collector.walk(expr)
        return collector.literals.filter { !isInertLiteral($0, within: Syntax(expr)) }
    }

    /// Whether `body` contains a call ending `.auth.require(…)`.
    static func requiresAuthentication(_ body: some SyntaxProtocol) -> Bool {
        body.description.contains(".auth.require(")
    }
}

/// Every string literal under a node.
private final class LiteralCollector: SyntaxVisitor {
    var literals: [StringLiteralExprSyntax] = []

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        literals.append(node)
        return .skipChildren
    }
}
