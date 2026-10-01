import SwiftSyntax

/// `#expect(a == b)` on floating-point values, restated as the comparison it already was.
///
/// `XCTAssertEqual(a, b)` without `accuracy:` asserted IEEE 754 equality. So does
/// `a.isEqual(to: b)`, with the difference that a reader, and `exact-double-equality`, can see
/// it was meant. Swapping in a tolerance here would change what the test claims, and a fixer
/// that loosens assertions to make a checker quiet is the thing the checker exists to stop.
enum NamedComparison {

    /// The edit that names the comparison of the `#expect` containing `position`, if its
    /// condition is a single `==` or `!=`.
    ///
    /// - Parameters:
    ///   - position: Where the gate reported the comparison.
    ///   - tree: The file it reported it in.
    ///   - elementwise: Whether the operands are collections of floats.
    /// - Returns: A UTF-8 byte range in the file and the text to put there, or `nil` when the
    ///   condition has any other shape. That case is left for the gate to report.
    static func edit(
        at position: AbsolutePosition, in tree: SourceFileSyntax, elementwise: Bool,
        optionalFunctions: Set<String>
    ) -> (range: Range<Int>, text: String)? {
        guard let token = tree.token(at: position),
              let expectation = enclosingExpectation(of: Syntax(token)),
              let whole = expectation.arguments.first?.expression
        else { return nil }

        let condition = Operand.strip(whole)
        guard let sequence = condition.expression.as(SequenceExprSyntax.self),
              sequence.elements.count == 3
        else { return nil }
        let elements = Array(sequence.elements)
        guard let op = elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text,
              op == "==" || op == "!="
        else { return nil }
        // The parser attaches a leading `try` to the first operand, not the comparison:
        // `try a == b` is `[try a, ==, b]`. Each side's effects move to the front, so the
        // `try` still covers both once the comparison is a method call.
        let lhs = Operand.strip(elements[0])
        let rhsOperand = Operand.strip(elements[2])
        let prefix = Operand.prefix(condition.effects, lhs.effects, rhsOperand.effects)

        let rhs = rhsOperand.expression.trimmedDescription
        let method = elementwise
            ? "elementsEqual(\(rhs), by: { $0.isEqual(to: $1) })"
            : "isEqual(to: \(rhs))"
        let named: String
        switch optionality(of: lhs.expression, optionalFunctions: optionalFunctions) {
        case .chained:
            named = "(\(lhs.expression.trimmedDescription))?.\(method) == true"
        case .returned:
            named = "\(Operand.receiver(lhs.expression))?.\(method) == true"
        case .notKnownOptional:
            named = "\(Operand.receiver(lhs.expression)).\(method)"
        }
        let text = prefix + (op == "!=" ? "!" + named : named)

        let start = whole.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = whole.endPositionBeforeTrailingTrivia.utf8Offset
        return (start..<end, text)
    }

    /// How the left operand is known to be optional, as far as syntax can tell.
    private enum Optionality {
        /// An optional chain, `a?.b`: one optional, however many `?` it passes through.
        case chained
        /// A call to a function this file declares as returning an optional.
        case returned
        /// Neither. A value optional for another reason still fails to compile, at a line
        /// the compiler names.
        case notKnownOptional
    }

    /// `XCTAssertEqual` accepted `[Double]?` against `[Double]`, because `Optional` is
    /// `Equatable`. `isEqual(to:)` does not, so an optional operand compares through `?.` and
    /// `== true`: still exact, and `nil` still fails.
    private static func optionality(of expression: ExprSyntax, optionalFunctions: Set<String>) -> Optionality {
        var spine: ExprSyntax? = expression
        while let node = spine {
            if node.is(OptionalChainingExprSyntax.self) { return .chained }
            if node.is(ForceUnwrapExprSyntax.self) { return .notKnownOptional }
            if let member = node.as(MemberAccessExprSyntax.self) {
                spine = member.base
            } else if let call = node.as(FunctionCallExprSyntax.self) {
                if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                    return optionalFunctions.contains(callee.baseName.text) ? .returned : .notKnownOptional
                }
                spine = call.calledExpression
            } else if let subscriptCall = node.as(SubscriptCallExprSyntax.self) {
                spine = subscriptCall.calledExpression
            } else {
                return .notKnownOptional
            }
        }
        return .notKnownOptional
    }

    /// The nearest `#expect` around `node`.
    private static func enclosingExpectation(of node: Syntax) -> MacroExpansionExprSyntax? {
        var current: Syntax? = node
        while let candidate = current {
            if let macro = candidate.as(MacroExpansionExprSyntax.self), macro.macroName.text == "expect" {
                return macro
            }
            current = candidate.parent
        }
        return nil
    }
}
