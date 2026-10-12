import Foundation
import SwiftSyntax

// MARK: - Facts

/// What one body establishes beyond the checks ``FallbackGuardFacts`` reads: what its
/// locals were computed from, which values a guard holds at or above zero, and which
/// collections were tested as a whole.
///
/// ``FallbackGuardFacts`` answers "was this name checked?". A survey of the portfolio
/// found the commonest false positive was a value checked under one name and
/// converted under another — `guard k >= 0, k <= 1`, then `let rank = k * Double(n - 1)`
/// and `Int(rank)`. These are the facts that let a check be followed to the value
/// computed from what it checked.
struct FallbackDerivedFacts {

    /// A `let`, and what it was initialised from.
    struct LetBinding {
        /// The initialiser.
        let value: ExprSyntax
        /// UTF-8 offset of the end of the declaration. The name means this value
        /// only after it.
        let endOffset: Int
    }

    /// A collection whose every element was tested.
    struct CollectionProof {
        /// The collection, as ``FallbackSubjectKey`` names it.
        let key: String
        /// What was shown of each element: ``FallbackGuardFacts/Kind/finite`` or
        /// ``FallbackGuardFacts/Kind/notNaN``.
        let kind: FallbackGuardFacts.Kind
        /// UTF-8 offset from which the proof holds.
        let offset: Int
    }

    /// A value a guard asserts is zero or more.
    struct SignProof {
        /// The value, as ``FallbackSubjectKey`` names it.
        let key: String
        /// UTF-8 offset of the guard condition.
        let offset: Int
    }

    /// The element of a loop over a collection that was tested whole.
    struct ElementProof {
        /// The loop's element name.
        let name: String
        /// The collection it is drawn from, as ``FallbackSubjectKey`` names it.
        let collection: String
        /// What was shown of each element.
        let kind: FallbackGuardFacts.Kind
        /// UTF-8 offsets of the loop body. The name means an element only inside it:
        /// a later loop may reuse it over a collection nothing tested.
        let body: Range<Int>
    }

    /// A value that was written to: `x = y`, `x += y`, `&x`.
    struct Assignment {
        /// The value, as ``FallbackSubjectKey`` names it.
        let key: String
        /// UTF-8 offset of the write.
        let offset: Int
    }

    /// Locals declared exactly once in the body, with `let`.
    var lets: [String: LetBinding] = [:]

    /// Loop elements drawn from a collection that was tested whole.
    var elements: [ElementProof] = []

    /// Every write the body makes to a value it names.
    var assignments: [Assignment] = []

    /// Values a guard asserts are zero or more: `guard span > 0`, `guard 0 <= x`.
    var nonNegative: [SignProof] = []

    /// Collections a guard tested whole, and filtered copies of them.
    var collections: [CollectionProof] = []

    /// Ordinary checks this reading adds: a value in a named constant range.
    var facts: [FallbackGuardFacts.Fact] = []
}

// MARK: - Collector

/// Reads ``FallbackDerivedFacts`` out of one body.
///
/// A nested closure or function is its own body and is not entered: a `let` inside a
/// closure is not a local of the function around it, and following a name to the
/// wrong initialiser would clear a conversion nothing bounded.
final class FallbackDerivedFactCollector: SyntaxVisitor {
    private let genericNames: Set<String>
    private let ranges: FallbackRangeConstants

    private var result = FallbackDerivedFacts()
    private var declarationCounts: [String: Int] = [:]
    private var filteredCopies: [FallbackDerivedFacts.CollectionProof] = []
    private var loops: [Loop] = []
    private var localRanges: [String: Int] = [:]
    private var localMemberships: [LocalMembership] = []

    /// A `for` loop over a collection, waiting to learn whether it was proven.
    private struct Loop {
        let element: String
        let collection: String
        let body: Range<Int>
    }

    /// `guard name.contains(x)`, waiting to learn whether `name` is a local declared
    /// once, as a constant range.
    private struct LocalMembership {
        let range: String
        let subject: String
        let offset: Int
    }

    private init(genericNames: Set<String>, ranges: FallbackRangeConstants) {
        self.genericNames = genericNames
        self.ranges = ranges
        super.init(viewMode: .sourceAccurate)
    }

    /// Collects what a body establishes.
    ///
    /// - Parameters:
    ///   - body: The body: a code block, a closure's statements, an accessor block.
    ///   - genericNames: Generic parameters in scope that are floating-point.
    ///   - ranges: The constant ranges a `contains` test may be read against.
    static func collect(
        from body: Syntax,
        genericNames: Set<String>,
        ranges: FallbackRangeConstants
    ) -> FallbackDerivedFacts {
        let collector = FallbackDerivedFactCollector(genericNames: genericNames, ranges: ranges)
        collector.walk(body)
        return collector.finished()
    }

    /// Collects what a file's top-level statements establish. Types declared at file
    /// scope are their members' business, not the script's.
    static func collectTopLevel(
        from file: SourceFileSyntax,
        genericNames: Set<String>,
        ranges: FallbackRangeConstants
    ) -> FallbackDerivedFacts {
        let collector = FallbackDerivedFactCollector(genericNames: genericNames, ranges: ranges)
        for item in file.statements {
            collector.walk(item)
        }
        return collector.finished()
    }

    /// Resolves what could only be decided once the whole body was read.
    private func finished() -> FallbackDerivedFacts {
        // A name bound twice is two values. Neither initialiser is followed.
        result.lets = result.lets.filter { declarationCounts[$0.key] == 1 }
        result.collections.append(contentsOf: filteredCopies.filter { declarationCounts[$0.key] == 1 })

        for loop in loops {
            for proof in result.collections
            where proof.key == loop.collection && proof.offset <= loop.body.lowerBound {
                result.elements.append(FallbackDerivedFacts.ElementProof(
                    name: loop.element, collection: loop.collection, kind: proof.kind, body: loop.body))
            }
        }

        // `let allowed = 0.0...1.0` in this body, then `guard allowed.contains(x)`.
        // Read here rather than from the file's constants: a local vouches for the
        // body that declares it, and for no other use of its name.
        for membership in localMemberships {
            guard declarationCounts[membership.range] == 1,
                  let declared = localRanges[membership.range],
                  declared <= membership.offset else {
                continue
            }
            for kind in [FallbackGuardFacts.Kind.lowerBound, .upperBound] {
                result.facts.append(FallbackGuardFacts.Fact(
                    key: membership.subject, kind: kind, offset: membership.offset, isAsserted: true))
            }
        }
        return result
    }

    private func key(of expr: ExprSyntax) -> String? {
        FallbackSubjectKey.key(of: expr, genericNames: genericNames)
    }

    // MARK: Other bodies

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    // MARK: Locals

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        declarationCounts[node.identifier.text, default: 0] += 1
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.bindingSpecifier.tokenKind == .keyword(.let) else { return .visitChildren }
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let value = binding.initializer?.value else {
                continue
            }
            let name = pattern.identifier.text
            result.lets[name] = FallbackDerivedFacts.LetBinding(value: value, endOffset: end)
            if FallbackRangeConstantCollector.isLiteralRange(value) {
                localRanges[name] = end
            }

            // `let clean = values.filter { $0.isFinite }` holds only what passed.
            if let call = value.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
               callee.declName.baseName.text == "filter",
               let kind = Self.elementProof(in: call) {
                filteredCopies.append(FallbackDerivedFacts.CollectionProof(key: name, kind: kind, offset: end))
            }
        }
        return .visitChildren
    }

    // MARK: Guards

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        // What a guard asserts holds from the end of the guard on.
        let offset = node.endPositionBeforeTrailingTrivia.utf8Offset
        for condition in node.conditions {
            guard case .expression(let expr) = condition.condition else { continue }
            for conjunct in Self.conjuncts(of: expr) {
                read(conjunct: conjunct, offset: offset)
            }
        }
        return .visitChildren
    }

    /// The expressions a condition asserts: itself, or each side of its `&&`s. A
    /// condition holding an `||` asserts none of its parts.
    static func conjuncts(of condition: ExprSyntax) -> [[ExprSyntax]] {
        guard let sequence = condition.as(SequenceExprSyntax.self) else {
            if let infix = condition.as(InfixOperatorExprSyntax.self) {
                return [[infix.leftOperand, infix.operator, infix.rightOperand]]
            }
            return [[condition]]
        }
        var parts: [[ExprSyntax]] = [[]]
        for element in sequence.elements {
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

    private func read(conjunct: [ExprSyntax], offset: Int) {
        if conjunct.count == 3, let op = conjunct[1].as(BinaryOperatorExprSyntax.self) {
            readSign(lhs: conjunct[0], operator: op.operator.text, rhs: conjunct[2], offset: offset)
            return
        }
        guard conjunct.count == 1,
              let call = conjunct[0].as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
              let base = callee.base else {
            return
        }
        switch callee.declName.baseName.text {
        case "contains":
            // `guard degreesOfFreedomRange.contains(df)`, against a constant range.
            guard call.arguments.count == 1,
                  let only = call.arguments.first,
                  only.label == nil,
                  let subject = key(of: only.expression) else {
                return
            }
            let position = call.positionAfterSkippingLeadingTrivia.utf8Offset
            guard ranges.isConstantRange(base) else {
                if let local = base.as(DeclReferenceExprSyntax.self) {
                    localMemberships.append(LocalMembership(
                        range: local.baseName.text, subject: subject, offset: position))
                }
                return
            }
            for kind in [FallbackGuardFacts.Kind.lowerBound, .upperBound] {
                result.facts.append(FallbackGuardFacts.Fact(
                    key: subject, kind: kind, offset: position, isAsserted: true))
            }
        case "allSatisfy":
            // `guard cashFlows.allSatisfy({ !$0.isNaN })`.
            guard let collection = key(of: base), let kind = Self.elementProof(in: call) else { return }
            result.collections.append(FallbackDerivedFacts.CollectionProof(
                key: collection, kind: kind, offset: offset))
        default:
            return
        }
    }

    /// Records `x > 0`, `x >= 0`, `0 < x` and `0 <= x`, against any literal that is
    /// zero or more.
    private func readSign(lhs: ExprSyntax, operator text: String, rhs: ExprSyntax, offset: Int) {
        let subject: ExprSyntax
        switch text {
        case ">", ">=":
            guard NumericLiteralFacts.threshold(of: rhs, conversions: genericNames) != nil else { return }
            subject = lhs
        case "<", "<=":
            guard NumericLiteralFacts.threshold(of: lhs, conversions: genericNames) != nil else { return }
            subject = rhs
        default:
            return
        }
        guard let key = key(of: subject) else { return }
        result.nonNegative.append(FallbackDerivedFacts.SignProof(key: key, offset: offset))
    }

    // MARK: Collections

    /// What the predicate of `allSatisfy` or `filter` shows of each element it
    /// passes: `{ $0.isFinite }`, `{ !$0.isNaN }`, `\.isFinite`, or either as one
    /// side of an `&&`.
    static func elementProof(in call: FunctionCallExprSyntax) -> FallbackGuardFacts.Kind? {
        let predicate: ExprSyntax
        if let closure = call.trailingClosure, call.arguments.isEmpty {
            predicate = ExprSyntax(closure)
        } else if call.arguments.count == 1, let only = call.arguments.first, call.trailingClosure == nil {
            predicate = only.expression
        } else {
            return nil
        }

        if let keyPath = predicate.as(KeyPathExprSyntax.self) {
            return keyPath.root == nil && keyPath.components.trimmedDescription == ".isFinite" ? .finite : nil
        }
        guard let closure = predicate.as(ClosureExprSyntax.self),
              closure.statements.count == 1,
              let only = closure.statements.first,
              case .expr(let body) = only.item else {
            return nil
        }
        for conjunct in conjuncts(of: body) where conjunct.count == 1 {
            if isElementTest(conjunct[0], named: "isFinite") { return .finite }
            if let negated = conjunct[0].as(PrefixOperatorExprSyntax.self),
               negated.operator.text == "!",
               isElementTest(negated.expression, named: "isNaN") {
                return .notNaN
            }
        }
        return nil
    }

    /// True for `$0.isFinite` — the named property, read straight off the element.
    private static func isElementTest(_ expr: ExprSyntax, named name: String) -> Bool {
        guard let member = expr.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == name,
              let element = member.base?.as(DeclReferenceExprSyntax.self) else {
            return false
        }
        return element.baseName.text == "$0"
    }

    // MARK: Writes

    private static let compoundAssignments: Set<String> = ["+=", "-=", "*=", "/=", "%="]

    /// True for `=` and for the compound assignments.
    private static func isAssignment(_ op: ExprSyntax) -> Bool {
        if op.is(AssignmentExprSyntax.self) { return true }
        guard let binary = op.as(BinaryOperatorExprSyntax.self) else { return false }
        return compoundAssignments.contains(binary.operator.text)
    }

    private func recordWrite(to target: ExprSyntax, at offset: Int) {
        guard let key = key(of: target) else { return }
        result.assignments.append(FallbackDerivedFacts.Assignment(key: key, offset: offset))
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        if elements.count >= 3, Self.isAssignment(elements[1]) {
            recordWrite(to: elements[0], at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        }
        return .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if Self.isAssignment(node.operator) {
            recordWrite(to: node.leftOperand, at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        }
        return .visitChildren
    }

    override func visit(_ node: InOutExprSyntax) -> SyntaxVisitorContinueKind {
        recordWrite(to: node.expression, at: node.positionAfterSkippingLeadingTrivia.utf8Offset)
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        let body = node.body.positionAfterSkippingLeadingTrivia.utf8Offset
            ..< node.body.endPositionBeforeTrailingTrivia.utf8Offset

        // `for value in values`
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self), let collection = key(of: node.sequence) {
            loops.append(Loop(element: pattern.identifier.text, collection: collection, body: body))
            return .visitChildren
        }

        // `for (index, value) in values.enumerated()`
        guard let tuple = node.pattern.as(TuplePatternSyntax.self),
              tuple.elements.count == 2,
              let element = tuple.elements.last?.pattern.as(IdentifierPatternSyntax.self),
              let call = node.sequence.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
              callee.declName.baseName.text == "enumerated",
              let base = callee.base,
              let collection = key(of: base) else {
            return .visitChildren
        }
        loops.append(Loop(element: element.identifier.text, collection: collection, body: body))
        return .visitChildren
    }
}
