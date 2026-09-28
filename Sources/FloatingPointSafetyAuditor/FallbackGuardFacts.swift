import Foundation
import SwiftSyntax

// MARK: - Subject keys

/// Names the value an expression stands for, so a check written on it in one
/// place can be matched to a use of it in another.
enum FallbackSubjectKey {

    /// The key for `expr`, or nil when the expression is not a plain reference.
    ///
    /// `tenor`, `entry.tenor` and `self.tenor` are references. So is
    /// `Double(budget)`, which is `budget` in another type — a check on one is a
    /// check on the other. `rate * 1_000_000` is not: it is a different value,
    /// and a bound on `rate` says nothing certain about it.
    ///
    /// - Parameters:
    ///   - expr: The expression to name.
    ///   - genericNames: Generic parameters in scope that are floating-point, so
    ///     that `T(budget)` is read as a conversion.
    ///   - depth: Recursion budget for unwrapping. Guarded so the walk terminates
    ///     on any input.
    static func key(of expr: ExprSyntax, genericNames: Set<String> = [], depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }

        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        if expr.is(MemberAccessExprSyntax.self) {
            return normalised(expr.trimmedDescription)
        }
        if let chained = expr.as(OptionalChainingExprSyntax.self) {
            return key(of: chained.expression, genericNames: genericNames, depth: depth + 1)
        }
        if let unwrapped = expr.as(ForceUnwrapExprSyntax.self) {
            return key(of: unwrapped.expression, genericNames: genericNames, depth: depth + 1)
        }
        if let tuple = expr.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first,
           only.label == nil {
            return key(of: only.expression, genericNames: genericNames, depth: depth + 1)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           FallbackTypes.floatingPointTypeNames.contains(callee.baseName.text)
            || genericNames.contains(callee.baseName.text),
           call.arguments.count == 1,
           let only = call.arguments.first,
           only.label == nil {
            return key(of: only.expression, genericNames: genericNames, depth: depth + 1)
        }
        return nil
    }

    /// A member-access spelling with whitespace, optional-chaining marks and a
    /// leading `self.` removed, so `self.entry?.tenor` and `entry.tenor` agree.
    static func normalised(_ text: String) -> String {
        var result = text.filter { !$0.isWhitespace && $0 != "?" && $0 != "!" }
        if result.hasPrefix("self.") {
            result = String(result.dropFirst("self.".count))
        }
        return result
    }
}

// MARK: - Facts

/// What one function body establishes about the values it handles.
struct FallbackGuardFacts: Sendable {

    /// A kind of check.
    enum Kind: Sendable, Hashable {
        /// `x.isFinite`
        case finite
        /// `x > a`, `x >= a`
        case lowerBound
        /// `x < b`, `x <= b`
        case upperBound
        /// `abs(x) < b`, `x.magnitude < b`
        case magnitudeBound
    }

    /// One check, on one value, at one place.
    struct Fact: Sendable {
        /// The value checked, as ``FallbackSubjectKey`` names it.
        let key: String
        /// What was checked.
        let kind: Kind
        /// UTF-8 offset of the check, so a check after a use does not count for it.
        let offset: Int
        /// Whether a `guard` asserts it: the check is a condition of the guard
        /// itself, un-negated and not one side of an `||`, so the code after the
        /// guard runs only when it held.
        ///
        /// An asserted comparison excludes a NaN on its own, because no
        /// comparison with a NaN is true. One that is merely *computed* — bound
        /// to a local, negated, tested in an `if` — excludes nothing.
        let isAsserted: Bool
    }

    /// Every check found.
    var facts: [Fact] = []

    /// Locals that are another value under a new name: `let sizable = Double(budget)`.
    var aliases: [String: String] = [:]

    /// The kinds of check made on any of `keys` before `offset`.
    ///
    /// - Parameters:
    ///   - keys: The names the value goes by.
    ///   - offset: Where the value is used.
    ///   - assertedOnly: Count only checks a `guard` asserts.
    func kinds(for keys: Set<String>, before offset: Int, assertedOnly: Bool = false) -> Set<Kind> {
        var found: Set<Kind> = []
        for fact in facts where fact.offset < offset && keys.contains(fact.key) {
            if assertedOnly && !fact.isAsserted { continue }
            found.insert(fact.kind)
        }
        return found
    }

    /// `key`, plus every name that is the same value: its aliases, and what it
    /// is itself an alias of.
    func equivalents(of key: String) -> Set<String> {
        var keys: Set<String> = [key]
        if let target = aliases[key] {
            keys.insert(target)
        }
        for (alias, target) in aliases where target == key {
            keys.insert(alias)
        }
        return keys
    }
}

// MARK: - Collector

/// Reads the checks out of one function body.
///
/// It records that a check was *written*, not that it was written correctly. A
/// bound with the comparison reversed still counts as a bound. What the rule
/// needs from this is weaker than proof: evidence that the author asked the
/// question. Requiring `isFinite` alongside any bound is what keeps that honest,
/// because a NaN fails every comparison and so slips through a range test
/// written as two negations.
final class FallbackGuardFactCollector: SyntaxVisitor {
    private let genericNames: Set<String>

    /// What the walk found.
    private(set) var result = FallbackGuardFacts()

    /// The condition expressions of every `guard` seen so far.
    private var guardConditions: Set<SyntaxIdentifier> = []

    /// Creates a collector.
    /// - Parameter genericNames: Generic parameters in scope that are floating-point.
    init(genericNames: Set<String>) {
        self.genericNames = genericNames
        super.init(viewMode: .sourceAccurate)
    }

    /// Collects the facts a body establishes.
    static func collect(from body: Syntax, genericNames: Set<String>) -> FallbackGuardFacts {
        let collector = FallbackGuardFactCollector(genericNames: genericNames)
        collector.walk(body)
        return collector.result
    }

    private func record(_ key: String, _ kind: FallbackGuardFacts.Kind, at node: some SyntaxProtocol) {
        result.facts.append(FallbackGuardFacts.Fact(
            key: key,
            kind: kind,
            offset: node.positionAfterSkippingLeadingTrivia.utf8Offset,
            isAsserted: guardConditions.contains(node.id)
        ))
    }

    // MARK: Guards

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        for condition in node.conditions {
            guard case .expression(let expr) = condition.condition else { continue }

            // `a || b` holds when either side does, so it asserts neither.
            if let sequence = expr.as(SequenceExprSyntax.self), containsDisjunction(sequence) {
                continue
            }
            guardConditions.insert(expr.id)
        }
        return .visitChildren
    }

    private func containsDisjunction(_ sequence: SequenceExprSyntax) -> Bool {
        sequence.elements.contains { element in
            element.as(BinaryOperatorExprSyntax.self)?.operator.text == "||"
        }
    }

    private func key(of expr: ExprSyntax) -> String? {
        FallbackSubjectKey.key(of: expr, genericNames: genericNames)
    }

    // A nested function is its own body, with its own checks.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    // MARK: isFinite

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "isFinite",
           let base = node.base,
           let subject = key(of: base) {
            record(subject, .finite, at: node)
        }
        return .visitChildren
    }

    // MARK: Comparisons

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() {
            guard let op = element.as(BinaryOperatorExprSyntax.self) else { continue }
            let text = op.operator.text
            guard Self.comparisonOperators.contains(text) else { continue }

            let lessThan = text == "<" || text == "<="
            if let lhs = operand(in: elements, at: index - 1, neighbour: index - 2) {
                recordBound(on: lhs, isUpper: lessThan, at: node)
            }
            if let rhs = operand(in: elements, at: index + 1, neighbour: index + 2) {
                recordBound(on: rhs, isUpper: !lessThan, at: node)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self),
              Self.comparisonOperators.contains(op.operator.text) else {
            return .visitChildren
        }
        let lessThan = op.operator.text == "<" || op.operator.text == "<="
        recordBound(on: node.leftOperand, isUpper: lessThan, at: node)
        recordBound(on: node.rightOperand, isUpper: !lessThan, at: node)
        return .visitChildren
    }

    private static let comparisonOperators: Set<String> = ["<", "<=", ">", ">="]
    private static let logicalOperators: Set<String> = ["&&", "||"]

    /// The operand at `index`, provided it is the *whole* operand.
    ///
    /// In an unfolded sequence `a + b < c`, the element left of `<` is `b`, but
    /// what is being compared is `a + b`. The operand is taken only when the
    /// element beyond it is the edge of the sequence or a logical operator.
    private func operand(in elements: [ExprSyntax], at index: Int, neighbour: Int) -> ExprSyntax? {
        guard index >= 0, index < elements.count else { return nil }
        if neighbour >= 0, neighbour < elements.count {
            guard let op = elements[neighbour].as(BinaryOperatorExprSyntax.self),
                  Self.logicalOperators.contains(op.operator.text) else {
                return nil
            }
        }
        return elements[index]
    }

    private func recordBound(on expr: ExprSyntax, isUpper: Bool, at node: some SyntaxProtocol) {
        if let inner = magnitudeArgument(of: expr) {
            // A lower bound on a magnitude bounds nothing: `abs(x) > 1` is true
            // of 1e300.
            if isUpper, let subject = key(of: inner) {
                record(subject, .magnitudeBound, at: node)
            }
            return
        }
        if let subject = key(of: expr) {
            record(subject, isUpper ? .upperBound : .lowerBound, at: node)
        }
    }

    /// `x` from `abs(x)` or `x.magnitude`.
    private func magnitudeArgument(of expr: ExprSyntax) -> ExprSyntax? {
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           callee.baseName.text == "abs",
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

    // MARK: Range membership

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let callee = node.calledExpression.as(MemberAccessExprSyntax.self),
              callee.declName.baseName.text == "contains",
              let base = callee.base,
              isRangeLiteral(base),
              node.arguments.count == 1,
              let only = node.arguments.first,
              only.label == nil,
              let subject = key(of: only.expression) else {
            return .visitChildren
        }
        record(subject, .lowerBound, at: node)
        record(subject, .upperBound, at: node)
        return .visitChildren
    }

    /// True for `(a...b)` and `(a..<b)`. A named collection is not accepted:
    /// `allowed.contains(x)` may be a set, and membership of a set bounds nothing.
    private func isRangeLiteral(_ expr: ExprSyntax) -> Bool {
        guard let tuple = expr.as(TupleExprSyntax.self),
              tuple.elements.count == 1,
              let only = tuple.elements.first else {
            return false
        }
        if let sequence = only.expression.as(SequenceExprSyntax.self) {
            return sequence.elements.contains { element in
                guard let op = element.as(BinaryOperatorExprSyntax.self) else { return false }
                return op.operator.text == "..." || op.operator.text == "..<"
            }
        }
        if let infix = only.expression.as(InfixOperatorExprSyntax.self),
           let op = infix.operator.as(BinaryOperatorExprSyntax.self) {
            return op.operator.text == "..." || op.operator.text == "..<"
        }
        return false
    }

    // MARK: Aliases

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let initializer = binding.initializer,
                  let target = key(of: initializer.value) else {
                continue
            }
            let alias = pattern.identifier.text
            if alias != target {
                result.aliases[alias] = target
            }
        }
        return .visitChildren
    }
}
