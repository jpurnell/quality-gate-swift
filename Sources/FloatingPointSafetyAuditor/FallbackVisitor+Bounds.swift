import Foundation
import SwiftSyntax

/// What is known about where a floating-point value can lie.
///
/// Three independent facts, because `Swift.min` and `Swift.max` treat them
/// independently: `min(x, 1.0)` has an upper bound whatever `x` is, and is a number
/// only if `x` is. The bounds are conditional — "if this is a number, it is at least
/// something" — so that a bound learned from how a value was computed can be joined
/// to an `isFinite` learned from a guard on its name.
struct FallbackBounds: Equatable {
    /// Not a NaN.
    var isNumber = false
    /// If a number, at least some finite value.
    var hasLower = false
    /// If a number, at most some finite value.
    var hasUpper = false
    /// If a number, zero or more. Implies ``hasLower``.
    var isNonNegative = false

    /// Nothing is known.
    static let unknown = FallbackBounds()

    /// A number in a known finite range: a literal, or an integer converted upward.
    static func constant(nonNegative: Bool) -> FallbackBounds {
        FallbackBounds(isNumber: true, hasLower: true, hasUpper: true, isNonNegative: nonNegative)
    }

    /// A number, bounded on both sides: `Int(_:)` of it cannot trap on a NaN or an
    /// infinity, and its author has said how large it may be.
    var isRepresentable: Bool { isNumber && hasLower && hasUpper }

    /// What both of two alternatives guarantee.
    func meet(_ other: FallbackBounds) -> FallbackBounds {
        FallbackBounds(
            isNumber: isNumber && other.isNumber,
            hasLower: hasLower && other.hasLower,
            hasUpper: hasUpper && other.hasUpper,
            isNonNegative: isNonNegative && other.isNonNegative
        )
    }

    /// What either of two readings of the same value guarantees.
    func join(_ other: FallbackBounds) -> FallbackBounds {
        FallbackBounds(
            isNumber: isNumber || other.isNumber,
            hasLower: hasLower || other.hasLower,
            hasUpper: hasUpper || other.hasUpper,
            isNonNegative: isNonNegative || other.isNonNegative
        )
    }

    /// The bounds of `-x`.
    var negated: FallbackBounds {
        FallbackBounds(isNumber: isNumber, hasLower: hasUpper, hasUpper: hasLower, isNonNegative: false)
    }

    /// The bounds of `abs(x)`.
    var magnitude: FallbackBounds {
        FallbackBounds(isNumber: isNumber, hasLower: true, hasUpper: hasLower && hasUpper, isNonNegative: true)
    }
}

// Carrying a bound from the value that was checked to the value that is converted.
//
// The rule used to ask one question — was *this name* bounded? — and so reported
// `Int(rank)` under `guard k >= 0, k <= 1` and `let rank = k * Double(n - 1)`. This
// reads how a local was computed, and accepts the conversion when the arithmetic
// keeps the value a number inside a range.
//
// It proves less than it could and nothing it should not. Sums and products keep a
// bound only when every operand has one; a quotient keeps none unless the divisor is
// a nonzero literal; `min` and `max` are read with the one fact that makes them
// treacherous — each returns its first argument when either is a NaN.

extension FallbackVisitor {

    /// Functions that round, and so keep whatever bounds their argument had.
    private static let roundingFunctions: Set<String> = ["floor", "ceil", "round", "trunc", "rint"]

    /// Functions that map a finite value at or above zero to one below about 709.
    private static let logarithms: Set<String> = ["log", "log2", "log10"]

    /// Static members of a floating-point type that are small numbers. Not
    /// `greatestFiniteMagnitude`: it is finite, and nowhere near an `Int`.
    private static let smallConstants: Set<String> = [
        "zero", "pi", "ulpOfOne", "leastNormalMagnitude", "leastNonzeroMagnitude"
    ]

    // MARK: - Entry point

    /// Where `expr` can lie at `offset`.
    ///
    /// - Parameters:
    ///   - expr: The expression to read.
    ///   - offset: Where it is used. A check after this point does not count.
    ///   - depth: Recursion budget. Guarded so the walk terminates on any input.
    ///   - following: Locals whose initialisers are already being read, so that
    ///     `let x = x * 2` is not followed into itself.
    func bounds(
        of expr: ExprSyntax,
        before offset: Int,
        depth: Int = 0,
        following: Set<String> = []
    ) -> FallbackBounds {
        guard depth < 16 else { return .unknown }
        let next = depth + 1

        if expr.is(FloatLiteralExprSyntax.self) || expr.is(IntegerLiteralExprSyntax.self) {
            return .constant(nonNegative: true)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            let inner = bounds(of: prefix.expression, before: offset, depth: next, following: following)
            switch prefix.operator.text {
            case "-": return inner.negated
            case "+": return inner
            default: return .unknown
            }
        }
        if let tuple = expr.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first,
           only.label == nil {
            return bounds(of: only.expression, before: offset, depth: next, following: following)
        }
        if let sequence = expr.as(SequenceExprSyntax.self) {
            return bounds(ofRun: Array(sequence.elements), before: offset, depth: next, following: following)
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return bounds(
                ofRun: [infix.leftOperand, infix.operator, infix.rightOperand],
                before: offset, depth: next, following: following)
        }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            return bounds(of: ternary.thenExpression, before: offset, depth: next, following: following)
                .meet(bounds(of: ternary.elseExpression, before: offset, depth: next, following: following))
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return bounds(ofCall: call, before: offset, depth: next, following: following)
        }
        if expr.is(DeclReferenceExprSyntax.self) || expr.is(MemberAccessExprSyntax.self)
            || expr.is(SubscriptCallExprSyntax.self) {
            return bounds(ofReference: expr, before: offset, depth: next, following: following)
        }
        return .unknown
    }

    // MARK: - Names

    /// The bounds of a name, a member or an element: what was checked on it, joined
    /// with what it was computed from.
    private func bounds(
        ofReference expr: ExprSyntax,
        before offset: Int,
        depth: Int,
        following: Set<String>
    ) -> FallbackBounds {
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            let name = member.declName.baseName.text
            if name == "magnitude" {
                return bounds(of: base, before: offset, depth: depth, following: following).magnitude
            }
            // `T.zero` is a number. `T.infinity` and `T.greatestFiniteMagnitude` are
            // not bounds on anything an `Int` can hold.
            if let type = base.as(DeclReferenceExprSyntax.self),
               FallbackTypes.floatingPointTypeNames.contains(type.baseName.text)
                || genericNames.contains(type.baseName.text) {
                return Self.smallConstants.contains(name) ? .constant(nonNegative: true) : .unknown
            }
        }

        var found = FallbackBounds.unknown
        let local = expr.as(DeclReferenceExprSyntax.self)?.baseName.text
        var initializer: ExprSyntax?
        if let local, !following.contains(local) {
            initializer = letInitializer(named: local, before: offset)
        }

        if let initializer, let local {
            // A `let`: it is whatever it was computed from.
            found = bounds(
                of: initializer, before: offset, depth: depth,
                following: following.union([local]))
        } else if case .finite = evaluate(expr) {
            // A constant the file declares from a literal, or an integer converted
            // upward: a number of ordinary size.
            return .constant(nonNegative: false)
        }

        guard let key = FallbackSubjectKey.key(of: expr, genericNames: genericNames) else { return found }
        return found.join(checkedBounds(of: Subject(key: key, display: key), before: offset))
    }

    /// What the checks written on a value say about where it lies.
    ///
    /// On the bar the conversion rule has always used: a bound counts when a guard
    /// asserts it, or when it is written anywhere and `isFinite` is too.
    private func checkedBounds(of subject: Subject, before offset: Int) -> FallbackBounds {
        // The arm the conversion sits in asserts what its condition says, exactly as
        // a guard would for the code after it.
        let arm = subject.key.flatMap { enclosingArm[$0] } ?? []
        let written = checks(on: subject, before: offset).union(arm)
        let asserted = checks(on: subject, before: offset, assertedOnly: true).union(arm)
        let finite = written.contains(.finite)

        func holds(_ kind: FallbackGuardFacts.Kind) -> Bool {
            asserted.contains(kind) || (finite && written.contains(kind))
        }
        let nonNegative = subject.key.map { isAssertedNonNegative($0, before: offset) } ?? false
        return FallbackBounds(
            isNumber: excludesNaN(subject, before: offset) || !arm.isEmpty,
            hasLower: holds(.lowerBound) || holds(.magnitudeBound) || nonNegative,
            hasUpper: holds(.upperBound) || holds(.magnitudeBound),
            isNonNegative: nonNegative
        )
    }

    // MARK: - Calls

    private func bounds(
        ofCall call: FunctionCallExprSyntax,
        before offset: Int,
        depth: Int,
        following: Set<String>
    ) -> FallbackBounds {
        let arguments = call.arguments.filter { $0.label == nil }.map(\.expression)
        let unlabelled = arguments.count == call.arguments.count

        func argument(_ index: Int) -> FallbackBounds {
            bounds(of: arguments[index], before: offset, depth: depth, following: following)
        }

        if let name = FallbackTypes.freeFunctionName(of: call.calledExpression), unlabelled {
            // `Double(count)` is a number of ordinary size. `Double(x)` is `x`.
            if call.calledExpression.is(DeclReferenceExprSyntax.self),
               FallbackTypes.floatingPointTypeNames.contains(name) || genericNames.contains(name),
               arguments.count == 1 {
                switch evaluate(arguments[0]) {
                case .unknown: return .constant(nonNegative: false)
                case .literal, .finite, .carriesNaN: return argument(0)
                }
            }
            if name == "min" || name == "max", arguments.count == 2 {
                return Self.extremum(name, first: argument(0), second: argument(1))
            }
            if name == "abs" || name == "fabs", arguments.count == 1 {
                return argument(0).magnitude
            }
            if Self.roundingFunctions.contains(name), arguments.count == 1 {
                return argument(0)
            }
            if Self.logarithms.contains(name), arguments.count == 1 {
                // The logarithm of a finite value that is zero or more is at most
                // about 709, and is a number. It is `-infinity` at zero, so it has
                // no lower bound of its own.
                let value = argument(0)
                let finite = value.hasUpper || isCheckedFinite(arguments[0], before: offset)
                guard value.isNumber, value.isNonNegative, finite else { return .unknown }
                return FallbackBounds(isNumber: true, hasLower: false, hasUpper: true, isNonNegative: false)
            }
            return .unknown
        }

        guard let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
              let base = callee.base else {
            return .unknown
        }
        let receiver = bounds(of: base, before: offset, depth: depth, following: following)
        switch callee.declName.baseName.text {
        case "rounded":
            return receiver
        case "truncatingRemainder", "remainder":
            // Smaller in magnitude than the divisor — provided the dividend is
            // finite. The remainder of an infinity is a NaN.
            guard call.arguments.count == 1,
                  let divisor = call.arguments.first,
                  divisor.label?.text == "dividingBy",
                  FallbackTypes.isNonZeroNumericLiteral(divisor.expression),
                  receiver.isRepresentable || isCheckedFinite(base, before: offset) else {
                return .unknown
            }
            return .constant(nonNegative: false)
        default:
            return .unknown
        }
    }

    /// True if `expr` is a value `isFinite` was tested on before `offset`.
    private func isCheckedFinite(_ expr: ExprSyntax, before offset: Int) -> Bool {
        guard let key = FallbackSubjectKey.key(of: expr, genericNames: genericNames) else { return false }
        return checks(on: Subject(key: key, display: key), before: offset).contains(.finite)
    }

    /// The bounds of `min(first, second)` or `max(first, second)`.
    ///
    /// Both return `first` when either argument is a NaN. So the result is a number
    /// exactly when `first` is, and a bound taken from `second` holds only if
    /// `second` is itself a number — otherwise the result is `first`, unbounded.
    private static func extremum(_ name: String, first: FallbackBounds, second: FallbackBounds) -> FallbackBounds {
        if name == "min" {
            return FallbackBounds(
                isNumber: first.isNumber,
                hasLower: first.hasLower && second.hasLower,
                hasUpper: first.hasUpper || (second.isNumber && second.hasUpper),
                isNonNegative: first.isNonNegative && second.isNonNegative
            )
        }
        return FallbackBounds(
            isNumber: first.isNumber,
            hasLower: first.hasLower || (second.isNumber && second.hasLower),
            hasUpper: first.hasUpper && second.hasUpper,
            isNonNegative: first.isNonNegative || (second.isNumber && second.isNonNegative)
        )
    }

    // MARK: - Arithmetic

    private static let arithmeticOperators: Set<String> = ["+", "-", "*", "/"]

    /// The bounds of an unfolded run of operands and operators.
    private func bounds(
        ofRun elements: [ExprSyntax],
        before offset: Int,
        depth: Int,
        following: Set<String>
    ) -> FallbackBounds {
        guard depth < 16, !elements.isEmpty else { return .unknown }
        if elements.count == 1 {
            return bounds(of: elements[0], before: offset, depth: depth + 1, following: following)
        }

        // `condition ? a : b` is one of the two.
        if let index = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
           let ternary = elements[index].as(UnresolvedTernaryExprSyntax.self) {
            let otherwise = Array(elements[elements.index(after: index)...])
            return bounds(of: ternary.thenExpression, before: offset, depth: depth + 1, following: following)
                .meet(bounds(ofRun: otherwise, before: offset, depth: depth + 1, following: following))
        }

        var operands: [ExprSyntax] = []
        var operators: [String] = []
        for (index, element) in elements.enumerated() {
            if index % 2 == 0 {
                operands.append(element)
            } else if let op = element.as(BinaryOperatorExprSyntax.self),
                      Self.arithmeticOperators.contains(op.operator.text) {
                operators.append(op.operator.text)
            } else {
                // `??`, a comparison, a cast, an assignment: not arithmetic.
                return .unknown
            }
        }
        guard operands.count == operators.count + 1 else { return .unknown }
        let values = operands.map { bounds(of: $0, before: offset, depth: depth + 1, following: following) }

        // A lone quotient of two values that are zero or more is zero or more — or a
        // NaN, which an `isFinite` on the result's name is left to exclude.
        if operators == ["/"], !FallbackTypes.isNonZeroNumericLiteral(operands[1]) {
            let nonNegative = values[0].isNonNegative && values[1].isNonNegative
            return FallbackBounds(isNumber: false, hasLower: nonNegative, hasUpper: false, isNonNegative: nonNegative)
        }

        // Any other division is by a literal that is not zero, or nothing is known.
        for (index, op) in operators.enumerated() where op == "/" {
            guard FallbackTypes.isNonZeroNumericLiteral(operands[index + 1]) else { return .unknown }
        }

        // A difference of two values that are zero or more can be anything. A negative
        // literal divisor is not itself zero or more, so it needs no case of its own.
        let nonNegative = !operators.contains("-") && values.allSatisfy(\.isNonNegative)
        guard values.allSatisfy(\.isRepresentable) else {
            return FallbackBounds(isNumber: false, hasLower: nonNegative, hasUpper: false, isNonNegative: nonNegative)
        }
        return .constant(nonNegative: nonNegative)
    }

    // MARK: - The arm a conversion sits in

    /// What the conditions enclosing `node` assert, of each value, for the code in
    /// their own arm.
    ///
    /// `x > 0 ? Int(x) : 0` and `if x < limit { … Int(x) … }` run the conversion only
    /// when the comparison held. Only the arm the condition guards is read: in the
    /// `else`, and in the third operand of a ternary, the comparison was false — which
    /// is what every comparison with a NaN is.
    ///
    /// The walk stops at a function or a closure. A closure written inside an arm may
    /// run long after the condition was tested.
    ///
    /// - Parameter node: The conversion.
    /// - Returns: The kinds of check asserted, by the name of the value checked.
    func armAssertions(around node: Syntax) -> [String: Set<FallbackGuardFacts.Kind>] {
        var found: [String: Set<FallbackGuardFacts.Kind>] = [:]
        // Where the outermost arm that said anything begins.
        var armStart: Int?
        var child = node
        var remaining = 256
        while let parent = child.parent, remaining > 0 {
            remaining -= 1
            if parent.is(FunctionDeclSyntax.self) || parent.is(InitializerDeclSyntax.self)
                || parent.is(ClosureExprSyntax.self) || parent.is(AccessorDeclSyntax.self) {
                break
            }
            if let enclosing = parent.as(IfExprSyntax.self), child.id == Syntax(enclosing.body).id {
                for condition in enclosing.conditions {
                    guard case .expression(let expr) = condition.condition else { continue }
                    readArm(FallbackDerivedFactCollector.conjuncts(of: expr), into: &found)
                }
                armStart = enclosing.body.positionAfterSkippingLeadingTrivia.utf8Offset
            }
            // `condition ? node : other`, unfolded: the condition is what precedes
            // the `?` in the enclosing sequence, after any assignment.
            if let ternary = parent.as(UnresolvedTernaryExprSyntax.self),
               child.id == Syntax(ternary.thenExpression).id,
               let sequence = ternary.parent?.parent?.as(SequenceExprSyntax.self) {
                readArm(Self.conjuncts(before: ternary, in: sequence), into: &found)
                armStart = ternary.positionAfterSkippingLeadingTrivia.utf8Offset
            }
            child = parent
        }
        // A value written to inside the arm is no longer the value the condition
        // tested: `if x < limit { x = raw; Int(x) }`.
        guard let armStart else { return found }
        let use = node.positionAfterSkippingLeadingTrivia.utf8Offset
        return found.filter { !isWritten($0.key, from: armStart, before: use) }
    }

    /// The conjuncts of the condition that precedes `ternary` in `sequence`.
    private static func conjuncts(
        before ternary: UnresolvedTernaryExprSyntax,
        in sequence: SequenceExprSyntax
    ) -> [[ExprSyntax]] {
        var condition: [ExprSyntax] = []
        for element in sequence.elements {
            if element.id == ternary.id { break }
            if element.is(AssignmentExprSyntax.self) || element.is(UnresolvedTernaryExprSyntax.self) {
                condition = []
                continue
            }
            condition.append(element)
        }
        var parts: [[ExprSyntax]] = [[]]
        for element in condition {
            if let op = element.as(BinaryOperatorExprSyntax.self) {
                if op.operator.text == "||" { return [] }
                if op.operator.text == "&&" {
                    parts.append([])
                    continue
                }
            }
            parts[parts.count - 1].append(element)
        }
        return parts
    }

    private static let orderedOperators: Set<String> = ["<", "<=", ">", ">="]

    /// Records what each conjunct asserts: an ordered comparison bounds both of its
    /// sides, and `x.isFinite` is itself.
    private func readArm(_ conjuncts: [[ExprSyntax]], into found: inout [String: Set<FallbackGuardFacts.Kind>]) {
        func record(_ expr: ExprSyntax, isUpper: Bool) {
            if let inner = Self.magnitudeArgument(of: expr) {
                // A lower bound on a magnitude bounds nothing.
                guard isUpper, let key = FallbackSubjectKey.key(of: inner, genericNames: genericNames) else { return }
                found[key, default: []].insert(.magnitudeBound)
                return
            }
            guard let key = FallbackSubjectKey.key(of: expr, genericNames: genericNames) else { return }
            found[key, default: []].insert(isUpper ? .upperBound : .lowerBound)
        }

        for conjunct in conjuncts {
            if conjunct.count == 3,
               let op = conjunct[1].as(BinaryOperatorExprSyntax.self),
               Self.orderedOperators.contains(op.operator.text) {
                let lessThan = op.operator.text == "<" || op.operator.text == "<="
                record(conjunct[0], isUpper: lessThan)
                record(conjunct[2], isUpper: !lessThan)
            } else if conjunct.count == 1,
                      let member = conjunct[0].as(MemberAccessExprSyntax.self),
                      member.declName.baseName.text == "isFinite",
                      let base = member.base,
                      let key = FallbackSubjectKey.key(of: base, genericNames: genericNames) {
                found[key, default: []].insert(.finite)
            }
        }
    }
}
