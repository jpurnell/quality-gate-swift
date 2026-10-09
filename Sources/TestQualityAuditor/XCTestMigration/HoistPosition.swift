import SwiftSyntax

/// Whether a value inside a statement can be computed on the line before it instead.
///
/// Binding `let x = try #require(y)` ahead of the statement that used `XCTUnwrap(y)` evaluates
/// `y` whenever the statement is reached. That is the same program only if the original
/// evaluated it whenever the statement was reached. To the right of `&&`, in the second clause
/// of an `if`, or in a loop condition it did not, and moving it would unwrap a value the test
/// never asked for. Those positions are refused, and the caller declines the file.
enum HoistPosition {

    /// Whether `node`, inside `statement`, is evaluated exactly once every time `statement` runs.
    static func isUnconditional(_ node: Syntax, in statement: CodeBlockItemSyntax) -> Bool {
        var child = node
        while let parent = child.parent, child.id != statement.id {
            if skipsOrRepeats(child, in: parent) { return false }
            child = parent
        }
        return true
    }

    /// Whether statements can be placed before `statement` without changing what its block returns.
    ///
    /// A block of one expression may be an implicit return: `{ try XCTUnwrap(a[XCTUnwrap(b)]) }`.
    /// A second statement in front of it would need a `return` the original never wrote.
    ///
    /// - Parameter inlined: Closures whose statements the conversion moves into an `if` body,
    ///   where nothing is returned.
    static func allowsStatementsBefore(_ statement: CodeBlockItemSyntax, inlined: Set<SyntaxIdentifier>) -> Bool {
        guard let list = statement.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
              case .expr = statement.item
        else { return true }
        guard let owner = list.parent else { return true }
        if let closure = owner.as(ClosureExprSyntax.self) { return inlined.contains(closure.id) }
        if owner.is(AccessorBlockSyntax.self) { return false }
        guard let block = owner.as(CodeBlockSyntax.self), let declaration = block.parent else { return true }
        if let function = declaration.as(FunctionDeclSyntax.self) {
            return function.signature.returnClause == nil
        }
        return !declaration.is(AccessorDeclSyntax.self)
    }

    /// Whether `parent` evaluates `child` conditionally, lazily, or more than once.
    private static func skipsOrRepeats(_ child: Syntax, in parent: Syntax) -> Bool {
        if parent.is(ClosureExprSyntax.self) || parent.is(UnresolvedTernaryExprSyntax.self)
            || parent.is(WhileStmtSyntax.self) || parent.is(RepeatStmtSyntax.self)
            || parent.is(WhereClauseSyntax.self) || parent.is(SwitchCaseLabelSyntax.self)
            || parent.is(CatchClauseSyntax.self) {
            return true
        }
        if let conditions = parent.as(ConditionElementListSyntax.self) {
            return conditions.first?.id != child.id
        }
        if let ifExpr = parent.as(IfExprSyntax.self) {
            // An `else if` is an `if` in the else position: its condition runs only when the
            // first one failed.
            return ifExpr.parent?.is(IfExprSyntax.self) == true
        }
        if let ternary = parent.as(TernaryExprSyntax.self) {
            return ternary.condition.id != child.id
        }
        if let infix = parent.as(InfixOperatorExprSyntax.self) {
            return shortCircuits(infix.operator) && infix.leftOperand.id != child.id
        }
        if let sequence = parent.as(SequenceExprSyntax.self) {
            let branches = sequence.elements.contains {
                shortCircuits($0) || $0.is(UnresolvedTernaryExprSyntax.self)
            }
            return branches && sequence.elements.first?.id != child.id
        }
        return false
    }

    private static func shortCircuits(_ expression: ExprSyntax) -> Bool {
        guard let op = expression.as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
        return op == "&&" || op == "||" || op == "??"
    }
}
