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
        at position: AbsolutePosition, in tree: SourceFileSyntax, elementwise: Bool
    ) -> (range: Range<Int>, text: String)? {
        guard let token = tree.token(at: position),
              let expectation = enclosingExpectation(of: Syntax(token)),
              let condition = expectation.arguments.first?.expression
        else { return nil }

        var effects: [String] = []
        var core = condition
        while true {
            if let tryExpr = core.as(TryExprSyntax.self) {
                effects.append(tryExpr.tryKeyword.text + (tryExpr.questionOrExclamationMark?.text ?? ""))
                core = tryExpr.expression
            } else if let awaitExpr = core.as(AwaitExprSyntax.self) {
                effects.append("await")
                core = awaitExpr.expression
            } else {
                break
            }
        }

        guard let sequence = core.as(SequenceExprSyntax.self),
              sequence.elements.count == 3
        else { return nil }
        let elements = Array(sequence.elements)
        guard let op = elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text,
              op == "==" || op == "!="
        else { return nil }

        let lhs = Operand.receiver(elements[0])
        let rhs = elements[2].trimmedDescription
        let named = elementwise
            ? "\(lhs).elementsEqual(\(rhs), by: { $0.isEqual(to: $1) })"
            : "\(lhs).isEqual(to: \(rhs))"
        let prefix = effects.isEmpty ? "" : effects.joined(separator: " ") + " "
        let text = prefix + (op == "!=" ? "!" + named : named)

        let start = condition.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = condition.endPositionBeforeTrailingTrivia.utf8Offset
        return (start..<end, text)
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
