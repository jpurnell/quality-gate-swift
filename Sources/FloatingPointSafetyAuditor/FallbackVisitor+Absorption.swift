import Foundation
import QualityGateCore
import SwiftSyntax

// The two rules about a NaN that is *answered for*, rather than one that traps.
//
// Both rest on one fact: every comparison with a NaN is false. `Swift.min` and
// `Swift.max` are written as a comparison and a choice, so they return their
// first argument whenever either is a NaN. An `if x > 0 … else if x < 0 …` is
// two comparisons, and a NaN passes neither.

extension FallbackVisitor {

    // MARK: - Asking whether the question was asked

    /// True if something before `offset` shows the author considered a NaN in
    /// `subject`: an `isFinite` or `isNaN` test, or any comparison a `guard`
    /// asserts — which a NaN cannot pass.
    func excludesNaN(_ subject: Subject, before offset: Int) -> Bool {
        let written = checks(on: subject, before: offset)
        if written.contains(.finite) || written.contains(.notNaN) { return true }
        // A guard that asserts `x != 0` has asserted nothing about a NaN, which
        // is unequal to everything.
        let asserted = checks(on: subject, before: offset, assertedOnly: true)
        if asserted.contains(where: { $0 != .nonZero }) { return true }
        return excludedThroughDerivedLocal(subject, before: offset)
    }

    /// True if a guard asserts something of a local computed from `subject` by
    /// arithmetic: `let span = upper - lower`, then `guard span > 0`.
    ///
    /// A NaN in `upper` or in `lower` makes `span` a NaN, and a NaN passes no
    /// comparison — so the guard that let `span` through has refused both. That holds
    /// only while the arithmetic carries a NaN; ``nanCarriedKeys(of:depth:)`` stops at
    /// anything that might swallow one.
    private func excludedThroughDerivedLocal(_ subject: Subject, before offset: Int) -> Bool {
        guard let key = subject.key else { return false }
        // The operand as the conversion sees it must be the operand the `let` saw: a
        // closure parameter of the same name, bound deeper, is another value.
        let bound = bindingDepth(ofRootOf: key) ?? 0
        for binding in letBindings(before: offset)
        where binding.depth >= bound
            && Self.nanCarriedKeys(of: binding.value, genericNames: genericNames).contains(key) {
            let local = Subject(key: binding.name, display: binding.name)
            let asserted = checks(on: local, before: offset, assertedOnly: true)
            if asserted.contains(where: { $0 != .nonZero }) { return true }
        }
        return false
    }

    /// Functions of one argument that return a NaN whenever they are given one.
    /// `min`, `max` and `pow` are absent: each has an argument order or a value for
    /// which a NaN goes in and a number comes out.
    private static let nanCarryingFunctions: Set<String> = [
        "floor", "ceil", "round", "trunc", "rint", "abs", "fabs", "sqrt", "log", "log2", "log10", "exp"
    ]

    /// The values whose NaN would make `expr` a NaN.
    ///
    /// Sums, differences, products and quotients carry a NaN from any operand, as do
    /// negation, rounding and a conversion between floating-point types. Anything
    /// else — a clamp, a ternary, a `??`, a comparison — yields no names, because a
    /// NaN may not survive it.
    ///
    /// - Parameters:
    ///   - expr: The expression to read.
    ///   - genericNames: Generic parameters in scope that are floating-point.
    ///   - depth: Recursion budget. Guarded so the walk terminates on any input.
    static func nanCarriedKeys(of expr: ExprSyntax, genericNames: Set<String>, depth: Int = 0) -> Set<String> {
        guard depth < 12 else { return [] }
        let next = depth + 1

        if let sequence = expr.as(SequenceExprSyntax.self) {
            return nanCarriedKeys(ofRun: Array(sequence.elements), genericNames: genericNames, depth: next)
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return nanCarriedKeys(
                ofRun: [infix.leftOperand, infix.operator, infix.rightOperand],
                genericNames: genericNames, depth: next)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            guard prefix.operator.text == "-" || prefix.operator.text == "+" else { return [] }
            return nanCarriedKeys(of: prefix.expression, genericNames: genericNames, depth: next)
        }
        if let tuple = expr.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first,
           only.label == nil {
            return nanCarriedKeys(of: only.expression, genericNames: genericNames, depth: next)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let name = FallbackTypes.freeFunctionName(of: call.calledExpression),
               call.arguments.count == 1,
               let only = call.arguments.first,
               only.label == nil,
               nanCarryingFunctions.contains(name)
                || FallbackTypes.floatingPointTypeNames.contains(name)
                || genericNames.contains(name) {
                return nanCarriedKeys(of: only.expression, genericNames: genericNames, depth: next)
            }
            if let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
               callee.declName.baseName.text == "rounded" || callee.declName.baseName.text == "squareRoot",
               let base = callee.base {
                return nanCarriedKeys(of: base, genericNames: genericNames, depth: next)
            }
            return []
        }
        if let member = expr.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "magnitude",
           let base = member.base {
            return nanCarriedKeys(of: base, genericNames: genericNames, depth: next)
        }
        guard expr.is(DeclReferenceExprSyntax.self) || expr.is(MemberAccessExprSyntax.self)
                || expr.is(SubscriptCallExprSyntax.self),
              let key = FallbackSubjectKey.key(of: expr, genericNames: genericNames) else {
            return []
        }
        return [key]
    }

    private static let nanCarryingOperators: Set<String> = ["+", "-", "*", "/"]

    /// ``nanCarriedKeys(of:genericNames:depth:)`` for an unfolded run of operands and
    /// operators. Any operator that is not arithmetic yields nothing.
    static func nanCarriedKeys(ofRun elements: [ExprSyntax], genericNames: Set<String>, depth: Int) -> Set<String> {
        guard depth < 12 else { return [] }
        var keys: Set<String> = []
        for (index, element) in elements.enumerated() {
            if index % 2 == 1 {
                guard let op = element.as(BinaryOperatorExprSyntax.self),
                      nanCarryingOperators.contains(op.operator.text) else {
                    return []
                }
                continue
            }
            keys.formUnion(nanCarriedKeys(of: element, genericNames: genericNames, depth: depth + 1))
        }
        return elements.count % 2 == 1 ? keys : []
    }

    /// How `expr` is named in a message if it can carry a NaN to `offset`, or
    /// nil if it cannot or nothing is known about it.
    ///
    /// A quotient is always able to: `0 / 0` is a NaN, and both operands were
    /// finite. It reaches here as a carrier with no name, which nothing can have
    /// checked — so a check on the operands of a division says nothing about its
    /// result, and only a check on the result, bound to a local, counts.
    private func carrierOfNaN(_ expr: ExprSyntax, before offset: Int) -> String? {
        let unchecked = subjects(of: expr).contains { !excludesNaN($0, before: offset) }
        return unchecked ? expr.trimmedDescription : nil
    }

    // MARK: - fallback.clamp-absorbs-nan

    /// `min` or `max`, written bare or as `Swift.min` / `Swift.max`, with two
    /// unlabelled arguments.
    private func extremum(_ expr: ExprSyntax) -> (name: String, arguments: [ExprSyntax])? {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              call.arguments.count == 2,
              call.arguments.allSatisfy({ $0.label == nil }) else {
            return nil
        }
        let name: String
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            name = reference.baseName.text
        } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                  member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Swift" {
            name = member.declName.baseName.text
        } else {
            return nil
        }
        guard name == "min" || name == "max" else { return nil }
        return (name, call.arguments.map(\.expression))
    }

    /// Reports a nested `min` / `max` that turns a NaN into one of its bounds.
    ///
    /// Both functions return their first argument when either is a NaN. So the
    /// value survives only when it is first in the inner call *and* the inner
    /// call is first in the outer one; in the other six arrangements of three
    /// operands a NaN comes back as a bound.
    func checkClamp(_ node: FunctionCallExprSyntax) {
        guard let outer = extremum(ExprSyntax(node)) else { return }

        var innerIndex: Int?
        for (index, argument) in outer.arguments.enumerated() {
            if let inner = extremum(argument), inner.name != outer.name {
                innerIndex = index
                break
            }
        }
        guard let innerIndex,
              let inner = extremum(outer.arguments[innerIndex]),
              inner.arguments.count == 2,
              outer.arguments.count == 2 else {
            return
        }
        let bound = outer.arguments[1 - innerIndex]
        let operands = inner.arguments + [bound]
        guard operands.contains(where: { !subjects(of: $0).isEmpty }) else { return }
        clampsExamined += 1

        // Where a NaN in each operand ends up. Nil means it propagates.
        let innerIsFirst = innerIndex == 0
        let outcomes: [(operand: ExprSyntax, result: String?)] = [
            (inner.arguments[0], innerIsFirst ? nil : bound.trimmedDescription),
            (inner.arguments[1], inner.arguments[0].trimmedDescription),
            (bound, innerIsFirst ? "the clamp of the other two" : nil)
        ]

        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        for outcome in outcomes {
            guard let result = outcome.result,
                  let carrier = carrierOfNaN(outcome.operand, before: offset) else {
                continue
            }
            emitClamp(carrier: carrier, result: result, node: Syntax(node))
            return
        }
    }

    private func emitClamp(carrier: String, result: String, node: Syntax) {
        let location = node.startLocation(converter: converter)
        diagnostics.append(
            Diagnostic(
                severity: .warning,
                message: """
                A NaN in '\(carrier)' comes back from this clamp as '\(result)'. Swift.min and \
                Swift.max return their first argument when either is a NaN, so the clamp reports \
                a bound for a value that was never computed. A clamp corrects a value slightly \
                outside a range; it has no business deciding what an absent one means.
                """,
                filePath: filePath,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: FallbackRuleID.clampAbsorbsNaN,
                suggestedFix: """
                Test the value before clamping it — 'guard !x.isNaN else { return .nan }' — and \
                bind a computed value to a local first so there is something to test. Writing the \
                value first at both levels, 'max(min(x, upper), lower)', also propagates a NaN, \
                but nothing about that spelling tells the next reader the order matters.
                """
            )
        )
    }

    // MARK: - fallback.classification-omits-nan

    private static let orderedComparisons: Set<String> = ["<", "<=", ">", ">="]

    /// What one arm of an `if` chain does with the value it tests.
    private enum Arm {
        /// An ordered comparison of the named value.
        case compares(Subject)
        /// An `isNaN` or `isFinite` test of the named value.
        case asksWhetherNumber
    }

    /// Reads the single condition of one `if`, or returns nil if it is anything
    /// but a plain comparison or a plain NaN test.
    private func arm(of node: IfExprSyntax) -> Arm? {
        guard node.conditions.count == 1,
              let only = node.conditions.first,
              case .expression(let condition) = only.condition else {
            return nil
        }

        if Self.testsWhetherNumber(condition) { return .asksWhetherNumber }

        let operands: [ExprSyntax]
        if let sequence = condition.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            guard elements.count == 3,
                  let op = elements[1].as(BinaryOperatorExprSyntax.self),
                  Self.orderedComparisons.contains(op.operator.text) else {
                return nil
            }
            operands = [elements[0], elements[2]]
        } else if let infix = condition.as(InfixOperatorExprSyntax.self),
                  let op = infix.operator.as(BinaryOperatorExprSyntax.self),
                  Self.orderedComparisons.contains(op.operator.text) {
            operands = [infix.leftOperand, infix.rightOperand]
        } else {
            return nil
        }

        guard operands.count == 2,
              let subject = comparedSubject(operands[0], operands[1]) else {
            return nil
        }
        return .compares(subject)
    }

    /// `x.isNaN`, `x.isFinite`, or either negated.
    private static func testsWhetherNumber(_ expr: ExprSyntax) -> Bool {
        var tested = expr
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            tested = prefix.expression
        }
        guard let member = tested.as(MemberAccessExprSyntax.self) else { return false }
        let name = member.declName.baseName.text
        return name == "isNaN" || name == "isFinite"
    }

    /// `x` from `abs(x)`, `Swift.abs(x)` or `x.magnitude`.
    static func magnitudeArgument(of expr: ExprSyntax) -> ExprSyntax? {
        if let call = expr.as(FunctionCallExprSyntax.self),
           FallbackTypes.freeFunctionName(of: call.calledExpression) == "abs",
           call.arguments.count == 1,
           let only = call.arguments.first,
           only.label == nil {
            return only.expression
        }
        if let member = expr.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "magnitude",
           let base = member.base {
            return base
        }
        return nil
    }

    /// Reports an `if` / `else if` chain that sorts one floating-point value by
    /// ordered comparison and has no arm for a NaN.
    ///
    /// A trailing `else` is what makes the shape dangerous rather than merely
    /// incomplete: it reads as "everything that is left", and what is left
    /// includes a third of the domain nobody listed. Without one the NaN takes
    /// no arm at all, which is how a cash flow was dropped from a valuation.
    func checkClassification(_ node: IfExprSyntax) {
        // The head of a chain only. An `else if` is reached through its head.
        guard node.parent?.is(IfExprSyntax.self) != true else { return }

        var comparisons: [Subject] = []
        var current: IfExprSyntax? = node
        var hasTrailingElse = false
        var trailingElse: CodeBlockSyntax?
        var remaining = 64

        while let link = current, remaining > 0 {
            remaining -= 1
            guard let arm = arm(of: link) else { return }
            switch arm {
            case .asksWhetherNumber:
                return
            case .compares(let subject):
                comparisons.append(subject)
            }

            switch link.elseBody {
            case .ifExpr(let next):
                current = next
            case .codeBlock(let block):
                hasTrailingElse = true
                trailingElse = block
                current = nil
            case nil:
                current = nil
            }
        }

        guard comparisons.count >= 2,
              let subject = comparisons.first,
              comparisons.allSatisfy({ $0.key == subject.key }) else {
            return
        }
        classificationsExamined += 1

        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        guard !excludesNaN(subject, before: offset) else { return }
        // Inside `if x.isInfinite { … }` the value is an infinity, and both compare.
        guard !isInsideInfiniteArm(node, of: subject) else { return }
        // A NaN takes the trailing else, and the else hands it on: nothing is
        // answered for it.
        if let trailingElse, yields(subject, from: trailingElse) { return }

        let location = node.startLocation(converter: converter)
        let landing = hasTrailingElse
            ? """
            so it takes the trailing else — which reads as the case that is left, and is not
            """
            : "so it takes neither arm and is passed over without a trace"
        diagnostics.append(
            Diagnostic(
                severity: .warning,
                message: """
                '\(subject.display)' is sorted by \(comparisons.count) comparisons and nothing asks \
                whether it is a number. Every comparison with a NaN is false, \(landing). The chain \
                covers the number line only if a NaN is not on it.
                """,
                filePath: filePath,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: FallbackRuleID.classificationOmitsNaN,
                suggestedFix: """
                Decide what a NaN means here and say so: an arm that tests \
                '\(subject.display).isNaN', or a guard above the chain that refuses one.
                """
            )
        )
    }

    // MARK: - Where a NaN is not answered for

    /// True if `block` is one statement that returns, assigns or evaluates to a value
    /// that is a NaN whenever `subject` is.
    ///
    /// `else { clamped = p }` and `else { return -(spot - strike) }` pass a NaN on to
    /// whoever reads the result. `else { return 0 }` answers for it, and so does
    /// `else { return min(1, p) }`.
    ///
    /// One statement, and no more: with anything before it the name may have been
    /// rebound — `let p = fallback; return p` — and the value yielded is then not the
    /// value that was classified.
    private func yields(_ subject: Subject, from block: CodeBlockSyntax) -> Bool {
        guard let key = subject.key, block.statements.count == 1, let last = block.statements.last else {
            return false
        }

        let yielded: Set<String>
        switch last.item {
        case .stmt(let statement):
            guard let value = statement.as(ReturnStmtSyntax.self)?.expression else { return false }
            yielded = Self.nanCarriedKeys(of: value, genericNames: genericNames)
        case .expr(let expression):
            // `name = value`: what is yielded is the value.
            if let sequence = expression.as(SequenceExprSyntax.self) {
                let elements = Array(sequence.elements)
                if elements.count >= 3, elements[1].is(AssignmentExprSyntax.self) {
                    yielded = Self.nanCarriedKeys(
                        ofRun: Array(elements[2...]), genericNames: genericNames, depth: 0)
                    break
                }
            }
            if let infix = expression.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self) {
                yielded = Self.nanCarriedKeys(of: infix.rightOperand, genericNames: genericNames)
                break
            }
            yielded = Self.nanCarriedKeys(of: expression, genericNames: genericNames)
        case .decl:
            return false
        }
        return yielded.contains(key)
    }

    /// True if `node` sits in the body of an enclosing `if` that asserts
    /// `subject.isInfinite`. The `else` of such an `if` is not that body.
    private func isInsideInfiniteArm(_ node: IfExprSyntax, of subject: Subject) -> Bool {
        guard let key = subject.key else { return false }
        var child = Syntax(node)
        var remaining = 256
        while let parent = child.parent, remaining > 0 {
            remaining -= 1
            if parent.is(FunctionDeclSyntax.self) || parent.is(InitializerDeclSyntax.self) {
                return false
            }
            if let enclosing = parent.as(IfExprSyntax.self),
               child.id == Syntax(enclosing.body).id,
               assertsInfinite(enclosing.conditions, key: key) {
                return true
            }
            child = parent
        }
        return false
    }

    /// True if one of `conditions` is `x.isInfinite` for the value `key` names, alone
    /// or as one side of an `&&`.
    private func assertsInfinite(_ conditions: ConditionElementListSyntax, key: String) -> Bool {
        for condition in conditions {
            guard case .expression(let expr) = condition.condition else { continue }
            for conjunct in FallbackDerivedFactCollector.conjuncts(of: expr) where conjunct.count == 1 {
                guard let member = conjunct[0].as(MemberAccessExprSyntax.self),
                      member.declName.baseName.text == "isInfinite",
                      let base = member.base,
                      FallbackSubjectKey.key(of: base, genericNames: genericNames) == key else {
                    continue
                }
                return true
            }
        }
        return false
    }
}
