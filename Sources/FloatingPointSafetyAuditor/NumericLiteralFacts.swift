import Foundation
import SwiftSyntax

/// What a literal, written in source, says about zero.
///
/// `fp-division-unguarded` and `fallback.*` both ask whether a divisor can be
/// zero, and both ask whether a comparison's other side is a threshold. They
/// each had a recogniser, and the two disagreed about `max(n, 1)` — the same
/// drift that two copies of the equality rule showed. This is the one copy.
///
/// Syntax only. A named constant is not resolved: `epsilon` is a name, and what
/// it holds is not read.
enum NumericLiteralFacts {

    /// What the other side of a comparison is, when it is a literal.
    enum Threshold: Sendable, Equatable {
        /// `0`, `0.0`, `.zero`, `T(0)`.
        case zero
        /// A literal above zero, or one of the smallest-magnitude constants.
        case positive
    }

    /// Types whose single-argument initialiser is a numeric conversion, not a computation.
    static let numericConversions: Set<String> = [
        "Float", "Double", "CGFloat", "Float16", "Float32", "Float64", "Float80", "Decimal",
        "TimeInterval",
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64"
    ]

    /// Static members of a floating-point type that are small and not zero.
    private static let smallestMagnitudes: Set<String> = [
        "ulpOfOne", "leastNonzeroMagnitude", "leastNormalMagnitude"
    ]

    // MARK: - Divisors

    /// `2`, `100.0`, `T(12)`, `(365.25 * 24)`, `max(x, 1.0)` — and not `0`,
    /// `0.0`, `T(0)`.
    ///
    /// `max(e, -1)` is not accepted: a prefix `-` is an operator applied to a
    /// literal, not a literal, and the bound it gives is below zero.
    ///
    /// - Parameters:
    ///   - expr: The divisor.
    ///   - depth: Recursion budget for nested wrappers. Guarded so the walk
    ///     terminates on any input.
    static func isNonZero(_ expr: ExprSyntax, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }
        if let literal = expr.as(IntegerLiteralExprSyntax.self) {
            return isNonZero(integerText: literal.literal.text)
        }
        if let literal = expr.as(FloatLiteralExprSyntax.self) {
            return isNonZero(floatText: literal.literal.text)
        }
        // `(365.25 * 24 * 3600)`: a product of literals, none of them zero.
        if let tuple = expr.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first,
           only.label == nil {
            guard let sequence = only.expression.as(SequenceExprSyntax.self) else {
                return isNonZero(only.expression, depth: depth + 1)
            }
            return sequence.elements.allSatisfy { element in
                if let op = element.as(BinaryOperatorExprSyntax.self) {
                    return op.operator.text == "*"
                }
                return isNonZero(element, depth: depth + 1)
            }
        }
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else {
            return false
        }
        // `max(x, 1.0)` is at least one.
        if callee.baseName.text == "max" {
            return call.arguments.contains { isNonZero($0.expression, depth: depth + 1) }
        }
        if call.arguments.count == 1, let only = call.arguments.first, only.label == nil {
            return isNonZero(only.expression, depth: depth + 1)
        }
        return false
    }

    private static func isNonZero(integerText text: String) -> Bool {
        text.contains { $0 != "0" && $0 != "_" }
    }

    private static func isNonZero(floatText text: String) -> Bool {
        text.prefix { $0 != "e" && $0 != "E" }.contains { $0.isNumber && $0 != "0" }
    }

    // MARK: - Thresholds

    /// What `expr` is as the other side of a comparison, or nil when it is not
    /// a literal at all.
    ///
    /// `x > n` compares two values; `x > 0` tests one. Only the second says
    /// anything about whether `x` can be divided by, and telling them apart is
    /// the whole job: a rule that takes any right-hand side as a threshold
    /// accepts `segLen > n` as a guard on `segLen`.
    ///
    /// A literal is read bare, in parentheses, or inside a numeric or generic
    /// conversion (`Double(0)`, `T(0)`). `-1` is not a literal.
    ///
    /// - Parameters:
    ///   - expr: The other side of the comparison.
    ///   - conversions: Names, beyond ``numericConversions``, whose
    ///     single-argument call is a conversion — the floating-point generic
    ///     parameters in scope.
    ///   - depth: Recursion budget for nested wrappers. Guarded so the walk
    ///     terminates on any input.
    static func threshold(of expr: ExprSyntax, conversions: Set<String> = [], depth: Int = 0) -> Threshold? {
        guard depth < 4 else { return nil }
        if let literal = expr.as(IntegerLiteralExprSyntax.self) {
            return isNonZero(integerText: literal.literal.text) ? .positive : .zero
        }
        if let literal = expr.as(FloatLiteralExprSyntax.self) {
            return isNonZero(floatText: literal.literal.text) ? .positive : .zero
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if name == "zero" { return .zero }
            return smallestMagnitudes.contains(name) ? .positive : nil
        }
        if let tuple = expr.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first,
           only.label == nil {
            return threshold(of: only.expression, conversions: conversions, depth: depth + 1)
        }
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
              numericConversions.contains(callee.baseName.text) || conversions.contains(callee.baseName.text),
              call.arguments.count == 1,
              let only = call.arguments.first,
              only.label == nil else {
            return nil
        }
        return threshold(of: only.expression, conversions: conversions, depth: depth + 1)
    }

    /// The threshold a run of sequence elements amounts to: one literal, or a
    /// product of them — `10 * .ulpOfOne`.
    ///
    /// Anything else in the run makes it a computation, and nil.
    static func threshold(ofRun elements: ArraySlice<ExprSyntax>, conversions: Set<String> = []) -> Threshold? {
        guard !elements.isEmpty else { return nil }
        var result = Threshold.positive
        for (offset, element) in elements.enumerated() {
            if offset % 2 == 1 {
                guard element.as(BinaryOperatorExprSyntax.self)?.operator.text == "*" else { return nil }
                continue
            }
            guard let factor = threshold(of: element, conversions: conversions) else { return nil }
            if factor == .zero { result = .zero }
        }
        return elements.count % 2 == 1 ? result : nil
    }
}
