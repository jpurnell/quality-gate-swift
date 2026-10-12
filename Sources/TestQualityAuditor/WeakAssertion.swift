import SwiftSyntax

/// `weak-assertion` — an assertion that a value is not zero, or not nil, and nothing more.
///
/// The claim is the same whichever framework states it. `#expect(x != nil)` and
/// `XCTAssertNotNil(x)` both pass for every value `x` could hold, so both are read here and
/// decided by one definition.
///
/// The definition is `#expect`'s: a `!=` whose neighbour is the literal `0` or `nil`. An
/// XCTest call is weak exactly when the `#expect` it converts to is, by the same table
/// `AssertionMapping` converts with. A migration therefore neither adds nor removes a
/// finding. BusinessMathExcel reported 0 before its migration and 84 after, because the rule
/// read only one of the two spellings.
enum WeakAssertion {

    /// What a weak comparison compares against.
    enum Literal: String {
        /// The integer literal `0`.
        case zero = "0"
        /// The literal `nil`.
        case absent = "nil"
    }

    /// One weak claim made by an `XCTAssert*` call.
    enum XCTestClaim: Equatable {
        /// The assertion is the comparison: `XCTAssertNotNil(x)`, `XCTAssertNotEqual(x, 0)`.
        case named(assertion: String, literal: Literal)
        /// The assertion carries a condition that holds the comparison:
        /// `XCTAssertTrue(x != nil)`.
        case condition
    }

    // MARK: - A condition, as `#expect` reads it

    /// How many weak comparisons `condition` makes at its top level.
    ///
    /// The parser leaves operators unfolded, so `a != nil && b != 0` is one flat sequence and
    /// counts twice. A comparison inside parentheses or a call is a different node and is not
    /// read: `#expect((a != nil) == flag)` asserts what `flag` says.
    static func weakComparisonCount(in condition: ExprSyntax) -> Int {
        if let sequence = condition.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            return elements.indices.count(where: { index in
                guard elements[index].as(BinaryOperatorExprSyntax.self)?.operator.text == "!=" else {
                    return false
                }
                let neighbours = [index - 1, index + 1].filter(elements.indices.contains)
                return neighbours.contains { literal(elements[$0]) != nil }
            })
        }

        // The folded form, should a caller fold operators before asking.
        if let infix = condition.as(InfixOperatorExprSyntax.self),
           infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "!=",
           literal(infix.leftOperand) != nil || literal(infix.rightOperand) != nil {
            return 1
        }
        return 0
    }

    /// `expression` as the literal a weak comparison is made against, if it is one.
    ///
    /// `0` only. `0.0` is a floating-point comparison and belongs to `exact-double-equality`.
    private static func literal(_ expression: ExprSyntax) -> Literal? {
        if expression.is(NilLiteralExprSyntax.self) { return .absent }
        if expression.as(IntegerLiteralExprSyntax.self)?.literal.text == "0" { return .zero }
        return nil
    }

    // MARK: - XCTest

    /// The weak claims `call` makes, if it is an `XCTAssert*` call that makes any.
    ///
    /// | XCTest | Swift Testing | Weak |
    /// |---|---|---|
    /// | `XCTAssertNotNil(x)` | `#expect(x != nil)` | always |
    /// | `XCTAssertNotEqual(a, b)` | `#expect(a != b)` | when `a` or `b` is `0` or `nil` |
    /// | `XCTAssertNotEqual(a, b, accuracy: e)` | `#expect(abs(a - b) > e)` | never |
    /// | `XCTAssertNotEqual([a], b)` | `#expect(![a].elementsEqual(b))` | never |
    /// | `XCTAssert(c)`, `XCTAssertTrue(c)` | `#expect(c)` | as `c` is |
    ///
    /// Every other assertion converts to something `#expect` does not report:
    /// `XCTAssertNil` to `== nil`, `XCTAssertGreaterThan(n, 0)` to `n > 0`, and
    /// `XCTAssertFalse(c)` to `!(c)`, which puts any comparison inside parentheses.
    static func xctestClaims(in call: FunctionCallExprSyntax) -> [XCTestClaim] {
        guard let assertion = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text else {
            return []
        }
        // `file:` and `line:` say where; `accuracy:` changes what is claimed. The rest are
        // the operands and then the message, in order.
        let operands = call.arguments
            .filter { argument in
                guard let label = argument.label?.text else { return true }
                return !["accuracy", "file", "line"].contains(label)
            }
            .map(\.expression)
        let hasAccuracy = call.arguments.contains { $0.label?.text == "accuracy" }

        switch assertion {
        case "XCTAssertNotNil":
            guard operands.first != nil else { return [] }
            return [.named(assertion: assertion, literal: .absent)]
        case "XCTAssertNotEqual":
            // Against an array literal the conversion is `!a.elementsEqual(b)`, which has no
            // `!=` in it.
            guard operands.count >= 2, !hasAccuracy, !operands[0].is(ArrayExprSyntax.self),
                  let literal = literal(operands[0]) ?? literal(operands[1]) else { return [] }
            return [.named(assertion: assertion, literal: literal)]
        case "XCTAssert", "XCTAssertTrue":
            guard let condition = operands.first else { return [] }
            return Array(repeating: .condition, count: weakComparisonCount(in: condition))
        default:
            return []
        }
    }
}
