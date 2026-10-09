import Foundation
import SwiftSyntax

/// Decides whether a divisor that is not a plain literal can be zero, from
/// what a ``DivisorFactIndex`` holds about the file.
///
/// It resolves a name to the literal it was bound to, folds literal
/// arithmetic, and carries a comparison through `+`, `-`, `*`, `max` and a
/// conversion — `guard n > 1` to `Double(n - 1)`. Anything it does not
/// recognise is "not known", and a divisor that is not known stays reported.
final class DivisorFactEvaluator {
    private let index: DivisorFactIndex
    private let conversions: Set<String>

    /// Work left for the query in progress. A divisor whose answer needs more
    /// than this is not known.
    private var budget = 0

    private static let queryBudget = 600
    private static let depthLimit = 14

    /// Where a query stands.
    private struct Site {
        /// Where names are looked up: the use, or the declaration of the
        /// `let` whose initializer is being read.
        let resolveAt: Int
        /// Where the divisor is. A claim has to hold here.
        let useAt: Int
        let depth: Int
        /// The width an integer literal has here: that of the annotation on
        /// the `let` being read, or the least an `Int` can be.
        var literalBits = DivisorConstant.unwrittenBits

        var deeper: Site {
            Site(resolveAt: resolveAt, useAt: useAt, depth: depth + 1, literalBits: literalBits)
        }

        /// An argument of a call: its literals take their own type.
        var argument: Site { Site(resolveAt: resolveAt, useAt: useAt, depth: depth + 1) }

        /// The initializer of a declaration written at `offset`.
        func resolving(at offset: Int, annotation: String? = nil) -> Site {
            let bits = annotation.flatMap { DivisorFactIndex.integerBits[$0] } ?? DivisorConstant.unwrittenBits
            return Site(resolveAt: offset, useAt: useAt, depth: depth + 1, literalBits: bits)
        }
    }

    /// Creates an evaluator over one file's facts.
    /// - Parameters:
    ///   - index: What the file says.
    ///   - conversions: Names whose single-argument call is a conversion to a
    ///     floating-point type.
    init(index: DivisorFactIndex, conversions: Set<String>) {
        self.index = index
        self.conversions = conversions.union(Self.floatingPointConversions)
    }

    private static let floatingPointConversions: Set<String> =
        NumericLiteralFacts.numericConversions.subtracting(DivisorFactIndex.integerBits.keys)

    /// True when `divisor` cannot be zero where it is written.
    func provesNonZero(_ divisor: ExprSyntax) -> Bool {
        budget = Self.queryBudget
        let offset = divisor.positionAfterSkippingLeadingTrivia.utf8Offset
        let site = Site(resolveAt: offset, useAt: offset, depth: 0)
        return fact(of: divisor, site)?.isNonZero ?? false
    }

    // MARK: - Expressions

    private func fact(of expr: ExprSyntax, _ site: Site) -> DivisorFact? {
        guard site.depth < Self.depthLimit, budget > 0 else { return nil }
        budget -= 1

        if let literal = expr.as(IntegerLiteralExprSyntax.self) {
            return Self.integer(literal.literal.text).map {
                .constant(DivisorConstant(integer: $0, bits: site.literalBits))
            }
        }
        if let literal = expr.as(FloatLiteralExprSyntax.self) {
            return Double(literal.literal.text.filter { $0 != "_" }).map { .constant(DivisorConstant(real: $0)) }
        }
        if let tuple = expr.as(TupleExprSyntax.self) {
            guard tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil else { return nil }
            return fact(of: only.expression, site.deeper)
        }
        if let sequence = expr.as(SequenceExprSyntax.self) {
            return fold(Array(sequence.elements), site.deeper)
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            return signed(prefix, site)
        }
        return reference(expr, site) ?? structured(expr, site)
    }

    private func signed(_ prefix: PrefixOperatorExprSyntax, _ site: Site) -> DivisorFact? {
        let operand = fact(of: prefix.expression, site.deeper)
        switch prefix.operator.text {
        case "-": return operand?.negated
        case "+": return operand
        default: return nil
        }
    }

    /// Names, members and subscripts: things a comparison can be about.
    private func reference(_ expr: ExprSyntax, _ site: Site) -> DivisorFact? {
        if let name = expr.as(DeclReferenceExprSyntax.self) {
            return named(name.baseName.text, site)
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return self.member(member, site)
        }
        if expr.is(SubscriptCallExprSyntax.self) {
            return claimed(expr, site)
        }
        return nil
    }

    /// Calls and already-folded operators.
    private func structured(_ expr: ExprSyntax, _ site: Site) -> DivisorFact? {
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return self.call(call, site)
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return fold([infix.leftOperand, infix.operator, infix.rightOperand], site.deeper)
        }
        if let ternary = expr.as(TernaryExprSyntax.self) {
            return .either(fact(of: ternary.thenExpression, site.deeper), fact(of: ternary.elseExpression, site.deeper))
        }
        return nil
    }

    private static func integer(_ literal: String) -> Int? {
        let digits = literal.filter { $0 != "_" }
        for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8)] where digits.hasPrefix(prefix) {
            return Int(digits.dropFirst(prefix.count), radix: radix)
        }
        return Int(digits)
    }

    // MARK: - Operators

    private static let precedence: [Set<String>] = [["<<", ">>"], ["*", "/", "%"], ["+", "-"]]

    /// The value of a run of sequence elements: `a * b - 1`, or `c ? a : b`.
    private func fold(_ run: [ExprSyntax], _ site: Site) -> DivisorFact? {
        guard site.depth < Self.depthLimit else { return nil }
        if run.count == 1, let only = run.first {
            return fact(of: only, site.deeper)
        }
        if let position = run.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }) {
            guard let ternary = run[position].as(UnresolvedTernaryExprSyntax.self),
                  !run.contains(where: { $0.is(AssignmentExprSyntax.self) }) else { return nil }
            return .either(fact(of: ternary.thenExpression, site.deeper),
                           fold(Array(run[(position + 1)...]), site.deeper))
        }
        guard var terms = operands(of: run, site) else { return nil }
        var operators = run.enumerated().compactMap { position, element in
            position % 2 == 1 ? element.as(BinaryOperatorExprSyntax.self)?.operator.text : nil
        }
        guard operators.count == terms.count - 1 else { return nil }
        for level in Self.precedence {
            guard Self.reduce(&terms, &operators, level) else { return nil }
        }
        return operators.isEmpty ? terms.first : nil
    }

    /// The value of every operand of a run, or nil when one is not known.
    private func operands(of run: [ExprSyntax], _ site: Site) -> [DivisorFact]? {
        guard run.count % 2 == 1 else { return nil }
        var terms: [DivisorFact] = []
        for (position, element) in run.enumerated() where position % 2 == 0 {
            guard let term = fact(of: element, site.deeper) else { return nil }
            terms.append(term)
        }
        return terms
    }

    /// Applies every operator of one precedence level, left to right.
    private static func reduce(_ terms: inout [DivisorFact], _ operators: inout [String], _ level: Set<String>) -> Bool {
        var position = 0
        while position < operators.count {
            guard level.contains(operators[position]) else {
                position += 1
                continue
            }
            guard position + 1 < terms.count,
                  let combined = apply(operators[position], terms[position], terms[position + 1]) else {
                return false
            }
            terms[position] = combined
            terms.remove(at: position + 1)
            operators.remove(at: position)
        }
        return true
    }

    private static func apply(_ operatorText: String, _ lhs: DivisorFact, _ rhs: DivisorFact) -> DivisorFact? {
        switch operatorText {
        case "+": return .sum(lhs, rhs)
        case "-": return .difference(lhs, rhs)
        case "*": return .product(lhs, rhs)
        default: return .constantOnly(lhs, operatorText, rhs)
        }
    }

    // MARK: - Names

    private func named(_ name: String, _ site: Site) -> DivisorFact? {
        let claim = claimed(key: name, names: [name], site)
        if let local = index.binding(name, at: site.resolveAt) {
            return .stronger(value(of: local, site), claim)
        }
        if let stored = index.memberOrGlobal(name, at: site.resolveAt) {
            return .stronger(storedValue(of: stored, site), claim)
        }
        return claim
    }

    /// `self.name`: a stored property, whatever local shares its name.
    private func stored(_ name: String, _ site: Site) -> DivisorFact? {
        let claim = claimed(key: name, names: [name], site)
        guard let stored = index.memberOrGlobal(name, at: site.resolveAt) else { return claim }
        return .stronger(storedValue(of: stored, site), claim)
    }

    /// What a local declaration says about its name.
    ///
    /// The initializer of a `let` is read with names resolved where it was
    /// written and claims required where the divisor is — so `let m = Double(n)`
    /// followed by `if n > 1 { x / (m - 1) }` is read as it runs.
    private func value(of binding: DivisorFactIndex.Binding, _ site: Site) -> DivisorFact? {
        switch binding.source {
        case .constant(let initializer, let annotation):
            let read = fact(of: initializer, site.resolving(at: binding.offset, annotation: annotation))
            return annotated(read, as: annotation)
        case .rangeIndex(let lower):
            let start = Site(resolveAt: binding.offset, useAt: binding.offset, depth: site.depth + 1)
            guard let bound = fold(lower, start)?.lowerBound else { return nil }
            return .atLeast(bound.value, strict: false)
        case .nonNegative:
            return .atLeast(0, strict: false)
        case .opaque:
            return nil
        }
    }

    /// What a stored property or a global says about its name. Its
    /// initializer is read where it is written: no guard in a function is a
    /// fact about it.
    private func storedValue(of binding: DivisorFactIndex.Binding, _ site: Site) -> DivisorFact? {
        guard case .constant(let initializer, let annotation) = binding.source else { return nil }
        let home = Site(resolveAt: binding.offset, useAt: binding.offset, depth: site.depth)
        return annotated(fact(of: initializer, home.resolving(at: binding.offset, annotation: annotation)), as: annotation)
    }

    /// Reads a value through the type its declaration wrote.
    ///
    /// Unannotated, an all-integer initializer is an `Int`: `let k = 1 / 2`
    /// is zero. A type this does not know makes the value unknown.
    private func annotated(_ fact: DivisorFact?, as annotation: String?) -> DivisorFact? {
        guard let fact else { return nil }
        guard let annotation else {
            guard case .constant(let constant) = fact, constant.integer != nil else { return fact }
            return fact.asInteger(bits: constant.bits)
        }
        if let bits = DivisorFactIndex.integerBits[annotation] {
            return fact.asInteger(bits: bits)
        }
        return floatingPoint(fact, as: annotation)
    }

    /// Types that hold every `Double`. A conversion to anything else may
    /// round two neighbouring values together.
    private static let wideFloatingPointTypes: Set<String> = ["Double", "Float64", "Float80", "TimeInterval"]

    private func floatingPoint(_ fact: DivisorFact, as typeName: String) -> DivisorFact? {
        guard conversions.contains(typeName) else { return nil }
        return fact.asFloatingPoint(narrowing: !Self.wideFloatingPointTypes.contains(typeName))
    }

    // MARK: - Members

    private func member(_ member: MemberAccessExprSyntax, _ site: Site) -> DivisorFact? {
        let name = member.declName.baseName.text
        if let standard = Self.standardConstant(member) { return standard }
        guard let base = member.base else { return nil }
        if name == "magnitude" {
            return .absolute(fact(of: base, site.deeper))
        }
        if let owner = base.as(DeclReferenceExprSyntax.self)?.baseName.text {
            if owner == "self" { return stored(name, site) }
            if let stored = staticMember(name, of: owner, site) { return stored }
        }
        let claim = claimed(ExprSyntax(member), site)
        return name == "count" ? .stronger(claim, count(of: base, site.deeper)) : claim
    }

    /// `Type.member` and `Self.member`, for a type this file declares.
    private func staticMember(_ name: String, of owner: String, _ site: Site) -> DivisorFact? {
        let typeName = owner == "Self" ? index.enclosingTypes(at: site.resolveAt).first?.name : owner
        guard let typeName, let stored = index.member(name, of: typeName) else { return nil }
        return storedValue(of: stored, site)
    }

    /// The standard library's nonzero constants.
    ///
    /// `leastNonzeroMagnitude` and `leastNormalMagnitude` are absent on
    /// purpose. Dividing by either overflows for almost any numerator, and
    /// `max(x, .leastNonzeroMagnitude)` in a denominator is that defect
    /// wearing a guard's clothes. `ulpOfOne` is the epsilon this rule has
    /// always read as a threshold, and is kept.
    private static func standardConstant(_ member: MemberAccessExprSyntax) -> DivisorFact? {
        let owner = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text
        guard member.base == nil || owner?.first?.isUppercase == true else { return nil }
        switch member.declName.baseName.text {
        case "pi": return .constant(DivisorConstant(real: .pi))
        case "ulpOfOne": return .atLeast(1e-19, strict: false)
        case "greatestFiniteMagnitude": return .atLeast(65504, strict: false)
        case "max":
            guard let owner, let bits = DivisorFactIndex.integerBits[owner] else { return nil }
            return .atLeast(Double(sign: .plus, exponent: bits - 1, significand: 1) - 1, strict: false)
        default: return nil
        }
    }

    /// The count of a collection: what was claimed of it, or of the
    /// collection it was mapped from. `xs.map { … }` has as many elements as
    /// `xs`, so `guard !xs.isEmpty` reaches `let ys = xs.map { … }`.
    private func count(of collection: ExprSyntax, _ site: Site) -> DivisorFact? {
        guard site.depth < Self.depthLimit, budget > 0 else { return nil }
        budget -= 1
        var best = claimedCount(of: collection, site)
        if let source = Self.countPreservingSource(of: collection) {
            best = .stronger(best, count(of: source, site.deeper))
        }
        if let name = collection.as(DeclReferenceExprSyntax.self)?.baseName.text,
           let local = index.binding(name, at: site.resolveAt),
           case .constant(let initializer, _) = local.source,
           let source = Self.countPreservingSource(of: initializer) {
            best = .stronger(best, count(of: source, site.resolving(at: local.offset)))
        }
        return best
    }

    private func claimedCount(of collection: ExprSyntax, _ site: Site) -> DivisorFact? {
        guard let key = FallbackSubjectKey.key(of: collection, genericNames: conversions) else { return nil }
        return claimed(key: key + ".count", names: Self.names(in: collection), site)
    }

    /// `xs` from `xs.map { … }`, `xs.sorted()`, `Array(xs)`.
    private static func countPreservingSource(of expr: ExprSyntax) -> ExprSyntax? {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }
        if let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
           DivisorFactIndex.countPreservingMethods.contains(callee.declName.baseName.text) {
            return callee.base
        }
        if call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Array",
           call.arguments.count == 1, let only = call.arguments.first, only.label == nil {
            return only.expression
        }
        return nil
    }

    // MARK: - Calls

    private func call(_ call: FunctionCallExprSyntax, _ site: Site) -> DivisorFact? {
        guard let name = Self.calleeName(of: call), call.trailingClosure == nil,
              call.arguments.allSatisfy({ $0.label == nil }) else { return nil }
        let arguments = call.arguments.map { fact(of: $0.expression, site.argument) }
        switch name {
        case "max": return .maximum(arguments)
        case "min": return .minimum(arguments)
        case "exp": return arguments.count == 1 ? .atLeast(0, strict: false) : nil
        default: break
        }
        guard arguments.count == 1, let only = arguments.first else { return nil }
        switch name {
        case "abs", "fabs": return .absolute(only)
        case "sqrt": return .squareRoot(only)
        default: return converted(only, by: name)
        }
    }

    private func converted(_ argument: DivisorFact?, by name: String) -> DivisorFact? {
        if let bits = DivisorFactIndex.integerBits[name] {
            return argument?.asInteger(bits: bits)
        }
        return argument.flatMap { floatingPoint($0, as: name) }
    }

    /// `max` from `max(…)` and from `Swift.max(…)`.
    private static func calleeName(of call: FunctionCallExprSyntax) -> String? {
        if let direct = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return direct.baseName.text
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Swift" else { return nil }
        return member.declName.baseName.text
    }

    // MARK: - Claims

    private static func names(in node: some SyntaxProtocol) -> Set<String> {
        var found: Set<String> = []
        for token in node.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let text) = token.tokenKind { found.insert(text) }
        }
        return found
    }

    private func claimed(_ expr: ExprSyntax, _ site: Site) -> DivisorFact? {
        guard let key = FallbackSubjectKey.key(of: expr, genericNames: conversions) else { return nil }
        return claimed(key: key, names: Self.names(in: expr), site)
    }

    /// What the comparisons that hold at the divisor say about `key`.
    ///
    /// A comparison counts when the divisor is inside the region it dominates
    /// and nothing it mentions was changed in between — counted from the
    /// comparison, or from the `let` being read if that came first.
    private func claimed(key: String, names: Set<String>, _ site: Site) -> DivisorFact? {
        var best: DivisorFact?
        for condition in index.conditions[key] ?? [] {
            best = .stronger(best, holding(condition, names: names, site))
        }
        for use in index.predicateUses where use.region.contains(site.useAt) {
            for guarantee in index.guarantees(of: use) {
                let subject = use.base.map { $0 + "." + guarantee.key } ?? guarantee.key
                guard subject == key else { continue }
                let asked = DivisorFactIndex.Condition(
                    key: subject, names: guarantee.names.union(use.base.map { [$0] } ?? []),
                    claim: guarantee.claim, region: use.region, offset: use.offset)
                best = .stronger(best, holding(asked, names: names, site, readAt: guarantee.offset))
            }
        }
        return best
    }

    private func holding(
        _ condition: DivisorFactIndex.Condition,
        names: Set<String>,
        _ site: Site,
        readAt: Int? = nil
    ) -> DivisorFact? {
        guard condition.region.contains(site.useAt) else { return nil }
        let start = min(site.resolveAt, condition.offset)
        let changed = index.isInvalidated(
            condition.key, names: names.union(condition.names), from: start, to: site.useAt)
        guard !changed else { return nil }
        let home = readAt ?? condition.offset
        return meaning(of: condition.claim, Site(resolveAt: home, useAt: home, depth: site.depth + 1))
    }

    private func meaning(of claim: DivisorFactIndex.Claim, _ site: Site) -> DivisorFact? {
        switch claim {
        case .nonZero:
            return .nonZero
        case .atLeastOne:
            return .atLeast(1, strict: false)
        case .above(let threshold, let strict):
            guard let bound = fold(threshold, site)?.lowerBound else { return nil }
            return .atLeast(bound.value, strict: strict || bound.strict)
        case .magnitudeAbove(let threshold, let strict):
            guard let bound = fold(threshold, site)?.lowerBound else { return nil }
            let excludesZero = bound.value > 0 || (bound.value >= 0 && (strict || bound.strict))
            return excludesZero ? .nonZero : nil
        }
    }
}
