import Foundation
import SwiftSyntax

/// What an expression is known to evaluate to.
///
/// The three cases are the three things a rule can honestly say about a value:
/// that it knows nothing, that the value is a number, or that it may not be one
/// and here is where that came from.
enum FallbackValue {
    /// Nothing is known. Integers, booleans and names with no declaration in
    /// reach all land here, and nothing is reported about them.
    case unknown
    /// An integer literal: a number in whatever type its neighbours have, and
    /// no evidence about what type that is.
    case literal
    /// Floating-point, and not able to be a NaN: literals, integers converted
    /// upward, and sums and products of those.
    case finite
    /// Floating-point, and able to be a NaN. The subjects are where one could
    /// have come from.
    case carriesNaN([FallbackVisitor.Subject])
}

extension FallbackVisitor {

    // MARK: - Entry points

    /// The floating-point values an expression could take a NaN from.
    ///
    /// Empty means "nothing here is known to be able to": literals, integers
    /// converted upward, and names with no declaration in reach.
    func subjects(of expr: ExprSyntax) -> [Subject] {
        guard case .carriesNaN(let found) = evaluate(expr) else { return [] }
        return found
    }

    /// True if `expr` names a collection of floating-point values.
    func isFloatingPointCollection(_ expr: ExprSyntax) -> Bool {
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return kind(ofName: reference.baseName.text) == .floatingPointCollection
        }
        guard let member = expr.as(MemberAccessExprSyntax.self), let base = member.base else {
            return false
        }
        let name = member.declName.baseName.text
        if Self.isSelf(base) {
            return kind(ofName: name) == .floatingPointCollection
        }
        return declarations.memberKinds[name] == .floatingPointCollection
    }

    /// Evaluates an expression.
    ///
    /// - Parameters:
    ///   - expr: The expression to read.
    ///   - depth: Recursion budget. Guarded so the walk terminates on any input.
    func evaluate(_ expr: ExprSyntax, depth: Int = 0) -> FallbackValue {
        guard depth < 12 else { return .unknown }
        let next = depth + 1

        if expr.is(FloatLiteralExprSyntax.self) {
            return .finite
        }
        if expr.is(IntegerLiteralExprSyntax.self) {
            return .literal
        }
        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return value(ofName: reference.baseName.text)
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return evaluate(member: member, depth: next)
        }
        if let element = expr.as(SubscriptCallExprSyntax.self) {
            guard isFloatingPointCollection(element.calledExpression) else { return .unknown }
            let text = element.trimmedDescription
            return .carriesNaN([Subject(key: FallbackSubjectKey.normalised(text), display: text)])
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return evaluate(call: call, depth: next)
        }
        if let sequence = expr.as(SequenceExprSyntax.self) {
            return evaluate(sequence: Array(sequence.elements), whole: expr, depth: next)
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return evaluate(
                sequence: [infix.leftOperand, infix.operator, infix.rightOperand],
                whole: expr,
                depth: next
            )
        }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            return Self.combine([
                evaluate(ternary.thenExpression, depth: next),
                evaluate(ternary.elseExpression, depth: next)
            ])
        }
        guard let inner = Self.wrapped(in: expr) else { return .unknown }
        return evaluate(inner, depth: next)
    }

    // MARK: - Pieces

    private func value(ofName name: String) -> FallbackValue {
        switch kind(ofName: name) {
        case .floatingPoint:
            return .carriesNaN([Subject(key: name, display: name)])
        case .finiteFloatingPoint:
            return .finite
        case .floatingPointCollection, .other, nil:
            return .unknown
        }
    }

    private static func isSelf(_ expr: ExprSyntax) -> Bool {
        guard let reference = expr.as(DeclReferenceExprSyntax.self) else { return false }
        return reference.baseName.text == "self" || reference.baseName.text == "Self"
    }

    private func isFloatingPointTypeName(_ expr: ExprSyntax) -> Bool {
        guard let reference = expr.as(DeclReferenceExprSyntax.self) else { return false }
        let name = reference.baseName.text
        return FallbackTypes.floatingPointTypeNames.contains(name) || genericNames.contains(name)
    }

    /// Static members of a floating-point type that are not numbers.
    private static let nonNumbers: Set<String> = ["nan", "signalingNaN", "infinity"]

    /// Static members of a floating-point type that are.
    private static let constants: Set<String> = [
        "zero", "pi", "ulpOfOne", "greatestFiniteMagnitude",
        "leastNormalMagnitude", "leastNonzeroMagnitude"
    ]

    /// Combines operands that flow into one result without dividing.
    private static func combine(_ values: [FallbackValue]) -> FallbackValue {
        var found: [Subject] = []
        var sawFinite = false
        for value in values {
            switch value {
            case .carriesNaN(let subjects): found.append(contentsOf: subjects)
            case .finite: sawFinite = true
            case .unknown, .literal: continue
            }
        }
        if !found.isEmpty { return .carriesNaN(found) }
        return sawFinite ? .finite : .unknown
    }

    /// Member names the standard library owns. A file that declares its own
    /// `count: Double` has said nothing about `values.count`.
    private static let standardLibraryMembers: Set<String> = [
        "count", "capacity", "startIndex", "endIndex", "underestimatedCount",
        "hashValue", "bitWidth", "exponent"
    ]

    /// The expression inside `try`, `await`, `( )`, `?`, `!` or a prefix
    /// operator — wrappers that change nothing about what the value is.
    private static func wrapped(in expr: ExprSyntax) -> ExprSyntax? {
        if let tryExpr = expr.as(TryExprSyntax.self) { return tryExpr.expression }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) { return awaitExpr.expression }
        if let chained = expr.as(OptionalChainingExprSyntax.self) { return chained.expression }
        if let unwrapped = expr.as(ForceUnwrapExprSyntax.self) { return unwrapped.expression }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            return prefix.operator.text == "!" ? nil : prefix.expression
        }
        if let tuple = expr.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first,
           only.label == nil {
            return only.expression
        }
        return nil
    }

    private func evaluate(member: MemberAccessExprSyntax, depth: Int) -> FallbackValue {
        let name = member.declName.baseName.text
        // `.zero` with no base could be a `CGPoint`. Nothing is known.
        guard let base = member.base else { return .unknown }

        // `self.periods` and `Self.deadline` are `periods` and `deadline`.
        if Self.isSelf(base) {
            return value(ofName: name)
        }

        // `Double.pi`, `T.zero`, `T.nan`.
        if isFloatingPointTypeName(base) {
            if Self.nonNumbers.contains(name) {
                let text = member.trimmedDescription
                return .carriesNaN([Subject(key: nil, display: text)])
            }
            return Self.constants.contains(name) ? .finite : .unknown
        }

        if Self.passthroughMembers.contains(name) {
            return evaluate(base, depth: depth)
        }

        guard !Self.standardLibraryMembers.contains(name) else { return .unknown }

        switch declarations.memberKinds[name] {
        case .floatingPoint:
            let text = member.trimmedDescription
            return .carriesNaN([Subject(key: FallbackSubjectKey.normalised(text), display: text)])
        case .finiteFloatingPoint:
            return .finite
        case .floatingPointCollection, .other, nil:
            return .unknown
        }
    }

    private func evaluate(call: FunctionCallExprSyntax, depth: Int) -> FallbackValue {
        let arguments = call.arguments.map { evaluate($0.expression, depth: depth) }

        if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = callee.baseName.text

            // `Double(x)` is `x`. `Double(count)` is a number.
            if FallbackTypes.floatingPointTypeNames.contains(name) || genericNames.contains(name) {
                let converted = Self.combine(arguments)
                if case .carriesNaN = converted { return converted }
                return .finite
            }

            // `floor(x)` is as much a number as `x` was.
            if Self.passthroughFunctions.contains(name) {
                return Self.combine(arguments)
            }

            // A function this file declares as returning floating-point. Its
            // result has no name, so nothing can have checked it.
            if declarations.returnKinds[name] == .floatingPoint, kind(ofName: name) == nil {
                return .carriesNaN([Subject(key: nil, display: call.trimmedDescription)])
            }
            return .unknown
        }

        guard let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
              let base = callee.base else {
            return .unknown
        }
        let name = callee.declName.baseName.text

        // `values.reduce(0.0, +)`: floating-point because its seed is, and a sum
        // over data is as clean as the data.
        if name == "reduce", let seed = arguments.first {
            switch seed {
            case .finite, .carriesNaN:
                return .carriesNaN([Subject(key: nil, display: call.trimmedDescription)])
            case .unknown, .literal:
                return .unknown
            }
        }

        if Self.passthroughMembers.contains(name) {
            return Self.combine([evaluate(base, depth: depth)] + arguments)
        }

        // `T.pow(a, b)`, `Double.maximum(a, b)`.
        if isFloatingPointTypeName(base) {
            return Self.combine(arguments)
        }
        return .unknown
    }

    private func evaluate(sequence elements: [ExprSyntax], whole: ExprSyntax, depth: Int) -> FallbackValue {
        // `condition ? a : b` — the condition chooses a value, it is not one.
        if let ternaryIndex = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }) {
            var values = Array(elements[elements.index(after: ternaryIndex)...])
            if let ternary = elements[ternaryIndex].as(UnresolvedTernaryExprSyntax.self) {
                values.append(ternary.thenExpression)
            }
            return Self.combine(values.map { evaluate($0, depth: depth) })
        }

        let operators = elements.compactMap { $0.as(BinaryOperatorExprSyntax.self)?.operator.text }
        // A comparison or a logical operator makes the whole thing a `Bool`.
        guard !operators.contains(where: { Self.booleanOperators.contains($0) }) else {
            return .unknown
        }

        let operands = elements.filter { !$0.is(BinaryOperatorExprSyntax.self) }
        let values = operands.map { evaluate($0, depth: depth) }
        let combined = Self.combine(values)
        if case .unknown = combined { return .unknown }

        // Something here is floating-point, so everything here is. An operand
        // nothing is known about is then a floating-point value of unknown
        // origin — which is not the same as a number.
        var found: [Subject] = []
        if case .carriesNaN(let subjects) = combined { found = subjects }
        for (operand, value) in zip(operands, values) {
            guard case .unknown = value else { continue }
            let text = operand.trimmedDescription
            found.append(Subject(
                key: FallbackSubjectKey.key(of: operand, genericNames: genericNames),
                display: text
            ))
        }

        // A quotient is a new place for a NaN to come from: `0 / 0`, with both
        // operands finite. Dividing by something known not to be zero is not.
        if dividesByUnknown(elements, at: whole.positionAfterSkippingLeadingTrivia.utf8Offset) {
            found.append(Subject(key: nil, display: whole.trimmedDescription))
        }
        return found.isEmpty ? .finite : .carriesNaN(found)
    }

    /// True if the sequence divides by something that could be zero.
    private func dividesByUnknown(_ elements: [ExprSyntax], at offset: Int) -> Bool {
        for (index, element) in elements.enumerated() {
            guard let op = element.as(BinaryOperatorExprSyntax.self),
                  op.operator.text == "/" || op.operator.text == "/=" else {
                continue
            }
            let divisorIndex = index + 1
            guard divisorIndex < elements.count else { return true }
            let divisor = elements[divisorIndex]
            if NumericLiteralFacts.isNonZero(divisor) { continue }
            if let key = FallbackSubjectKey.key(of: divisor, genericNames: genericNames),
               checks(on: Subject(key: key, display: key), before: offset).contains(.nonZero) {
                continue
            }
            return true
        }
        return false
    }
}
