import Foundation
import SwiftSyntax

/// Shapes that correlate with a test which passes without testing anything.
///
/// The rules in ``TestQualityAuditor`` proper are each a property of one assertion's
/// *syntax* — an exact `==` on a `Double`, a `try!`, a missing `#expect`. That is what
/// makes them fast and exact, and nothing here changes it.
///
/// These are different in kind. They cannot see the relationship between an assertion
/// and the thing under test — no syntactic rule can — so each one instead names a
/// *shape* that, in practice, is where vacuous tests are found. They are proxies, and
/// they are wrong sometimes. That is the trade being made: cheap and deterministic, in
/// exchange for a false-positive rate that has to be held down by the negative fixtures
/// in `SemanticTestRuleTests` rather than by cleverness here.
///
/// Each predicate is pure and takes a syntax node, so the interesting half of every rule
/// can be tested without a file, a parser fixture, or a `Configuration`.
enum SemanticTestRules {

    // MARK: - unvaried-parameter

    /// What a `@Test` body did, reduced to the three facts this rule needs.
    struct TestShape {
        /// Calls that are not assertions and not obvious test scaffolding.
        var subjectCalls: Int = 0
        /// Of those, how many passed nothing but literals.
        var allLiteralCalls: Int = 0
        /// `#expect` / `#require` expansions.
        var assertions: Int = 0
        /// Whether any assertion was `#expect(throws:)`.
        var assertsAThrow: Bool = false
    }

    /// Whether a call looks like fixture construction rather than a call under test.
    ///
    /// Swift's naming convention does the work: types are capitalised, functions are not.
    /// `DMU(name: "A", inputs: [1.0])` builds a value to test *with*; `solve(weight: 500)`
    /// is the thing being tested. Counting the first as the subject was the largest
    /// false-positive class in the corpus measurement — a test that constructs one fixture
    /// and asserts one thing about it looked identical to one that calls the code once.
    ///
    /// The convention is not a guarantee, so this can be wrong in both directions. It is a
    /// heuristic inside a `warning`-severity rule that already ships without call-graph
    /// resolution, and it removes far more noise than it introduces.
    static func looksLikeFixtureConstruction(_ call: FunctionCallExprSyntax) -> Bool {
        let name: String?
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            name = reference.baseName.text
        } else if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            name = member.declName.baseName.text
        } else {
            name = nil
        }
        guard let first = name?.first else { return false }
        return first.isUppercase
    }

    /// Whether a test cannot possibly detect that a parameter is ignored.
    ///
    /// The canonical failure is `#expect(solve(weight: 500).isFeasible)`: one call, fixed
    /// arguments, one assertion. It passes for an implementation that never reads `weight`,
    /// and it passes for one that returns a constant. Nothing about the test *varies*, so
    /// nothing about the result can be attributed to anything.
    ///
    /// The fix is to assert across a spread — a monotonicity, or a relation that has to hold
    /// at several values. Two call sites at different inputs distinguish an ignored
    /// parameter; one never can, however carefully the single expected value was chosen.
    ///
    /// ## The proxy, and what it cannot see
    ///
    /// The proposal notes this rule "needs call-graph resolution to distinguish the function
    /// under test from a helper", and that is true — this implementation does not have it,
    /// and counts any non-assertion call as a subject. A test whose single call is to a
    /// local fixture builder is therefore indistinguishable from one whose single call is to
    /// the code under test.
    ///
    /// It ships anyway, and at `warning`, because the measured shape is narrow enough to be
    /// useful without resolution: *exactly one* call, *every* argument a literal, and
    /// *exactly one* assertion. A test doing only that is thin whatever the callee turns out
    /// to be. Severity is the concession — this is a rule that starts a conversation, not
    /// one that stops a build.
    ///
    /// ## What the corpus removed
    ///
    /// A first draft counted every call and reported 141 tests. The samples were dominated
    /// by three correct shapes, each now excluded:
    ///
    /// - **Fixture construction** — `let dmu = DMU(name: "A", …)` then one assertion. The
    ///   call builds the value under test rather than being it; see
    ///   `looksLikeFixtureConstruction`.
    /// - **Conformance tests** — `#expect(sendable is DMU)`. There is no parameter to vary;
    ///   the test states a fact about a type. Excluded by the same rule, since the only call
    ///   is the constructor.
    /// - **Refusal tests** — `#expect(throws: SolverError.self) { try solve(weight: -1) }`.
    ///   Asserting that one specific input is rejected is a complete statement, and there is
    ///   nothing to spread it across.
    static func isUnvaried(_ shape: TestShape) -> Bool {
        guard !shape.assertsAThrow else { return false }
        return shape.subjectCalls == 1 && shape.allLiteralCalls == 1 && shape.assertions == 1
    }

    /// Whether every argument of a call is a literal.
    ///
    /// An empty argument list counts as literal — `compute()` varies nothing either.
    static func hasOnlyLiteralArguments(_ call: FunctionCallExprSyntax) -> Bool {
        call.arguments.allSatisfy { isLiteral($0.expression) }
    }

    /// Whether an expression is a literal value, including a negated or array literal.
    private static func isLiteral(_ expr: ExprSyntax) -> Bool {
        if expr.is(IntegerLiteralExprSyntax.self) { return true }
        if expr.is(FloatLiteralExprSyntax.self) { return true }
        if expr.is(BooleanLiteralExprSyntax.self) { return true }
        if expr.is(StringLiteralExprSyntax.self) { return true }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            return isLiteral(prefix.expression)
        }
        if let array = expr.as(ArrayExprSyntax.self) {
            return array.elements.allSatisfy { isLiteral($0.expression) }
        }
        return false
    }

    // MARK: - Reading a comparison

    /// One binary comparison, however the parser happened to shape it.
    struct Comparison {
        /// Left operand.
        let lhs: ExprSyntax
        /// The operator's spelling.
        let op: String
        /// Right operand.
        let rhs: ExprSyntax
    }

    /// Operators this rule set treats as making a claim about two values.
    private static let comparisonOperators: Set<String> = ["==", "!=", "<", "<=", ">", ">="]

    /// The comparison an expression makes, or `nil` if it does not make exactly one.
    ///
    /// `Parser.parse` does not fold operators, so an assertion arrives as a
    /// `SequenceExprSyntax` — and, crucially, a **flat** one. `scaled(x, y, z) == x * y / z`
    /// is seven elements, not three: `[call, ==, x, *, y, /, z]`. An earlier version of this
    /// function required exactly three, which silently returned `nil` for every assertion
    /// with arithmetic on either side — so the rules built on it would have reported nothing
    /// on precisely the expressions most worth reading, and looked like clean rules while
    /// doing it.
    ///
    /// The sequence is therefore split at its first comparison operator, and each side is
    /// re-wrapped as a sub-expression. `InfixOperatorExprSyntax` is handled too, because a
    /// folded tree is what a caller gets after `OperatorTable`.
    /// Logical connectives, which join several claims into one expression.
    private static let logicalOperators: Set<String> = ["&&", "||"]

    /// Every comparison an assertion makes, one per conjunct.
    ///
    /// `#expect(gap >= 0.0 && gap <= 100.0)` is two claims, and reading it as one was a
    /// measured false positive: splitting the flat sequence at the first comparison operator
    /// produced a right-hand side of `0.0 && gap <= 100.0`, which is not a literal, so the
    /// exemption that spares bounds checks did not recognise a bounds check.
    ///
    /// Conjuncts are split first, then each is read on its own.
    static func comparisons(in expr: ExprSyntax) -> [Comparison] {
        guard let sequence = expr.as(SequenceExprSyntax.self) else {
            return comparison(in: expr).map { [$0] } ?? []
        }

        var conjuncts: [[ExprSyntax]] = [[]]
        for element in sequence.elements {
            if let op = element.as(BinaryOperatorExprSyntax.self),
               logicalOperators.contains(op.operator.text) {
                conjuncts.append([])
            } else {
                conjuncts[conjuncts.count - 1].append(element)
            }
        }

        return conjuncts.compactMap { pieces in
            guard let rejoined = rejoin(pieces) else { return nil }
            return comparison(in: rejoined)
        }
    }

    static func comparison(in expr: ExprSyntax) -> Comparison? {
        if let sequence = expr.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            // A compound is not one comparison; `comparisons(in:)` splits it first.
            guard !elements.contains(where: { element in
                guard let op = element.as(BinaryOperatorExprSyntax.self) else { return false }
                return logicalOperators.contains(op.operator.text)
            }) else { return nil }

            guard let pivot = elements.firstIndex(where: { element in
                guard let op = element.as(BinaryOperatorExprSyntax.self) else { return false }
                return comparisonOperators.contains(op.operator.text)
            }) else { return nil }

            guard let op = elements[pivot].as(BinaryOperatorExprSyntax.self),
                  let lhs = rejoin(Array(elements[..<pivot])),
                  let rhs = rejoin(Array(elements[(pivot + 1)...])) else {
                return nil
            }
            return Comparison(lhs: lhs, op: op.operator.text, rhs: rhs)
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self),
           let op = infix.operator.as(BinaryOperatorExprSyntax.self),
           comparisonOperators.contains(op.operator.text) {
            return Comparison(
                lhs: infix.leftOperand, op: op.operator.text, rhs: infix.rightOperand)
        }
        return nil
    }

    /// One side of a split sequence, as a single expression.
    ///
    /// A lone element is returned as-is; several are re-wrapped in a `SequenceExprSyntax` so
    /// that callers walking the sub-tree see the operands and operators they expect.
    private static func rejoin(_ elements: [ExprSyntax]) -> ExprSyntax? {
        guard let first = elements.first else { return nil }
        guard elements.count > 1 else { return first }
        return ExprSyntax(SequenceExprSyntax(elements: ExprListSyntax(elements)))
    }

    /// The value of a numeric literal, ignoring a leading `-`.
    static func numericLiteral(_ expr: ExprSyntax) -> Double? {
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-" {
            return numericLiteral(prefix.expression).map { -$0 }
        }
        if let float = expr.as(FloatLiteralExprSyntax.self) {
            return Double(float.literal.text.replacingOccurrences(of: "_", with: ""))
        }
        if let integer = expr.as(IntegerLiteralExprSyntax.self) {
            return Double(integer.literal.text.replacingOccurrences(of: "_", with: ""))
        }
        return nil
    }

    // MARK: - non-strict-improvement

    /// Words in a test's name that claim the code got *better*, not merely that it is bounded.
    private static let improvementClaims = [
        "better", "improve", "beat", "exceed", "outperform"
    ]

    /// Whether a test's name claims an improvement.
    static func claimsImprovement(testName: String) -> Bool {
        let lowered = testName.lowercased()
        return improvementClaims.contains { lowered.contains($0) }
    }

    /// Whether a comparison lets a no-op satisfy a claim that something improved.
    ///
    /// `#expect(new <= old)` is true when `new == old`, so an implementation that changed
    /// nothing passes a test whose name says it made things better.
    ///
    /// ## Why a literal operand is exempt
    ///
    /// Of seven matches a grep produced across BusinessMath, five were bounds checks —
    /// `#expect(rate >= 0.0)` inside a test whose name happened to contain "improve". A
    /// comparison against a constant is not an improvement claim; it is a range assertion,
    /// and `>=` is exactly right for it. Requiring *both* operands to be computed removes
    /// that entire false-positive class, which is what makes this rule livable.
    ///
    /// The two real matches were in `ETSFittingTests` and are **correct as written**: they
    /// compare against a brute-force grid whose optimum can legitimately tie. That is the
    /// intended outcome — the rule surfaces the pair, a human decides, and the decision is
    /// recorded in a `// TEST-QUALITY:` comment. It is why this ships at `warning`.
    static func isNonStrictImprovement(_ comparison: Comparison) -> Bool {
        guard comparison.op == "<=" || comparison.op == ">=" else { return false }
        guard numericLiteral(comparison.lhs) == nil,
              numericLiteral(comparison.rhs) == nil else {
            return false
        }
        return true
    }

    // MARK: - tolerance-without-magnitude

    /// The ratio of an absolute tolerance to the magnitude it is measured against.
    ///
    /// For `#expect(abs(total - 1000.0) < 50.0)` this is `50.0 / 1000.0` — five percent,
    /// which asserts very little about a figure the test claims to know.
    ///
    /// ## What the ratio is for
    ///
    /// Not that loose tolerances are wrong; some quantities really are only known to a few
    /// percent. It is that a tolerance *loosened until the test passed* is invisible in
    /// review — the diff shows one number changing — and the ratio makes it legible. A
    /// reviewer seeing "the tolerance is 5% of the expected value" can ask whether that was
    /// derived or discovered.
    ///
    /// Returns `nil` when the expression has no literal magnitude to compare against: if
    /// both operands are computed, as in `abs(measured - expected) < 0.5`, there is nothing
    /// to take a ratio of, and a rule that guessed would be inventing evidence.
    static func toleranceRatio(_ comparison: Comparison) -> Double? {
        guard comparison.op == "<" || comparison.op == "<=" else { return nil }
        guard let tolerance = numericLiteral(comparison.rhs), tolerance > 0 else { return nil }
        guard isAbsoluteValueCall(comparison.lhs) else { return nil }

        let magnitude = largestNumericLiteral(in: comparison.lhs)
        guard let magnitude, magnitude > 0 else { return nil }
        return tolerance / magnitude
    }

    /// Whether an expression is a call to `abs(…)`.
    private static func isAbsoluteValueCall(_ expr: ExprSyntax) -> Bool {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return false }
        if call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "abs" {
            return true
        }
        // `.magnitude` and `x.distance(to:)` spell the same idea; only `abs` is claimed
        // here, because the others do not put the tolerance on the right of a comparison.
        return false
    }

    /// The largest absolute numeric literal anywhere inside an expression.
    private static func largestNumericLiteral(in expr: ExprSyntax) -> Double? {
        let scan = NumericLiteralScanner(viewMode: .sourceAccurate)
        scan.walk(expr)
        return scan.largest
    }

    /// Collects the largest magnitude among an expression's numeric literals.
    private final class NumericLiteralScanner: SyntaxVisitor {
        var largest: Double?

        override func visit(_ node: FloatLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            record(Double(node.literal.text.replacingOccurrences(of: "_", with: "")))
            return .visitChildren
        }

        override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            record(Double(node.literal.text.replacingOccurrences(of: "_", with: "")))
            return .visitChildren
        }

        private func record(_ value: Double?) {
            guard let value else { return }
            let magnitude = abs(value)
            if largest == nil || magnitude > (largest ?? 0) { largest = magnitude }
        }
    }

    // MARK: - assertion-on-constant

    /// Whether an assertion's condition never touches the code under test.
    ///
    /// `#expect(1.0 == 1.0)` passes for every possible implementation. This generalises
    /// `missing-assertion` from "this test has no assertions" to "this test has
    /// assertions, and none of them reach your code."
    ///
    /// ## Only the narrow form
    ///
    /// The condition must be built entirely from literals and operators — no calls, no
    /// identifiers, nothing that could reach the module. The proposal's broader reading
    /// ("no call *into the module under test*") needs to know which symbols belong to the
    /// module, which is call-graph resolution this rule does not have. The narrow form
    /// needs no such knowledge: an expression with no identifiers in it cannot reach any
    /// module at all, whoever owns it.
    static func isAssertionOnConstant(_ expr: ExprSyntax) -> Bool {
        let scan = ReachabilityScanner(viewMode: .sourceAccurate)
        scan.walk(expr)
        return scan.sawLiteral && !scan.sawSomethingReachable
    }

    /// Distinguishes an expression that could reach code from one that cannot.
    private final class ReachabilityScanner: SyntaxVisitor {
        var sawLiteral = false
        var sawSomethingReachable = false

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            sawSomethingReachable = true
            return .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            sawSomethingReachable = true
            return .visitChildren
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            sawSomethingReachable = true
            return .visitChildren
        }

        override func visit(_ node: FloatLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            sawLiteral = true
            return .visitChildren
        }

        override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            sawLiteral = true
            return .visitChildren
        }

        override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            sawLiteral = true
            return .visitChildren
        }
    }

    // MARK: - coalesced-assertion

    /// A `??` inside an asserted condition, and the value it fabricates.
    struct CoalescingSite {
        /// The fallback as written, for the diagnostic to quote.
        let fallback: String
    }

    /// Whether an assertion fabricates a value for one that may be missing.
    ///
    /// ```swift
    /// import Testing
    ///
    /// let periods = [7, 14, 28]
    /// let ma: [Int: Double] = [:]
    ///
    /// @Test func movingAverage() {
    ///     #expect(abs((ma[periods[0]] ?? 0) - 100.0) < 1e-6)
    /// }
    /// ```
    ///
    /// When the key is absent this does not report a missing key. It reports that `0` is not
    /// within `1e-6` of `100.0` — a failure about arithmetic, for a defect about lookup — and
    /// in the shapes where the fabricated value happens to satisfy the comparison, it reports
    /// nothing at all. Either way the assertion has stopped being about the optional. The fix
    /// is to require the value, so that absence is the thing that fails.
    ///
    /// BusinessMath grew 211 of these over roughly two years and every one was found by a
    /// human reading tests. The population is now zero, which is the whole argument for a
    /// rule: there is nothing left to find and everything left to prevent.
    ///
    /// ## Four carve-outs, three of them measured
    ///
    /// - **Only the asserted condition.** A fallback in the failure message —
    ///   `#expect(found?.count == 1, "got \(found ?? [])")` — cannot change whether the test
    ///   passes. The caller passes only the first unlabelled argument.
    /// - **Only a literal fallback.** `#expect((rHat ?? .infinity) < 1.1)` is correct: the
    ///   value is chosen precisely because it cannot be plausible, so absence *fails*. That
    ///   carve-out needs no special case — a poison value is never a literal, because its
    ///   whole purpose is to be recognisable as impossible. Anything computed
    ///   (`?? defaultScore()`) is likewise the test's own stated choice rather than a
    ///   fabrication buried in an assertion.
    /// - **`?? false`, unless negated.** `#expect(diag?.message.contains("x") ?? false)` is
    ///   the canonical Swift spelling of *non-nil and true*; absence yields `false` and the
    ///   assertion fails. Under a `!` the sense flips and absence passes, so the negated form
    ///   is flagged. This is conservative in one direction: `#expect((flags["a"] ?? false) ==
    ///   expected)` really is a fabrication and is not reported, because deciding that needs
    ///   to know what `expected` is.
    /// - **Not inside a closure.** `#expect(diagnostics.contains { ($0.ruleId ?? "").contains("x") })`
    ///   is correct and idiomatic: the fallback answers the *predicate*, where "missing means
    ///   does not match" is the right reading, and the search as a whole still fails if
    ///   nothing matches. This is the distinction `unasserted-optional-unwrap` already draws
    ///   — a value returned from a closure answers the closure, not the test — and without it
    ///   this rule reported fourteen findings on this repository's own suite, every one of
    ///   them correct code.
    ///
    /// A fallback inside string interpolation is skipped for the same reason as the message
    /// argument: it is formatting.
    ///
    /// ## What is deliberately not carved out
    ///
    /// A genuinely sparse map — a counter where "no entry" and "zero" are the same fact —
    /// makes `#expect((counts[k] ?? 0) >= 0)` correct, and this rule reports it. No instance
    /// was found in BusinessMath, and inventing a carve-out for a shape with no evidence
    /// behind it is how a rule acquires holes nobody can justify later. The recorded
    /// acknowledgement is the answer: `// TEST-QUALITY: coalesced-assertion — <reason>`.
    ///
    /// - Parameter condition: An assertion's first unlabelled argument.
    /// - Returns: The first fabricating fallback in it, or `nil`.
    static func coalescedLiteral(in condition: ExprSyntax) -> CoalescingSite? {
        let scan = CoalescingScanner(boundary: Syntax(condition).id, viewMode: .sourceAccurate)
        scan.walk(condition)
        return scan.site
    }

    /// Finds the first `??` whose fallback stands in for a value the assertion needed.
    private final class CoalescingScanner: SyntaxVisitor {
        /// The condition's own node; the negation walk stops here rather than escaping into
        /// the enclosing macro and file.
        let boundary: SyntaxIdentifier
        var site: CoalescingSite?

        init(boundary: SyntaxIdentifier, viewMode: SyntaxTreeViewMode) {
            self.boundary = boundary
            super.init(viewMode: viewMode)
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            .skipChildren
        }

        override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
            .skipChildren
        }

        /// `Parser.parse` does not fold operators, so `x ?? 0` arrives as a flat sequence.
        override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
            let elements = Array(node.elements)
            for (index, element) in elements.enumerated() {
                guard let op = element.as(BinaryOperatorExprSyntax.self),
                      op.operator.text == "??",
                      index + 1 < elements.count else {
                    continue
                }
                consider(fallback: elements[index + 1], at: Syntax(element))
            }
            return .visitChildren
        }

        /// The folded shape, which a caller gets after `OperatorTable`.
        override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
            if let op = node.operator.as(BinaryOperatorExprSyntax.self),
               op.operator.text == "??" {
                consider(fallback: node.rightOperand, at: Syntax(node.operator))
            }
            return .visitChildren
        }

        private func consider(fallback: ExprSyntax, at operatorNode: Syntax) {
            guard site == nil else { return }
            guard let rendered = SemanticTestRules.fabricatedFallback(fallback) else { return }
            if SemanticTestRules.isFalseLiteral(fallback),
               !SemanticTestRules.isNegated(operatorNode, upTo: boundary) {
                return
            }
            site = CoalescingSite(fallback: rendered)
        }
    }

    /// A fallback written as a literal, rendered as source, or `nil` if it is computed.
    ///
    /// Collection literals count: `?? []` fabricates an empty report as surely as `?? 0`
    /// fabricates a zero.
    static func fabricatedFallback(_ expr: ExprSyntax) -> String? {
        let bare = withoutParentheses(expr)
        let isLiteralShape = bare.is(IntegerLiteralExprSyntax.self)
            || bare.is(FloatLiteralExprSyntax.self)
            || bare.is(BooleanLiteralExprSyntax.self)
            || bare.is(StringLiteralExprSyntax.self)
            || bare.is(ArrayExprSyntax.self)
            || bare.is(DictionaryExprSyntax.self)
        if isLiteralShape { return rendered(bare) }
        if let prefix = bare.as(PrefixOperatorExprSyntax.self),
           prefix.operator.text == "-",
           numericLiteral(bare) != nil {
            return rendered(bare)
        }
        return nil
    }

    /// Whether an expression is the boolean literal `false`.
    static func isFalseLiteral(_ expr: ExprSyntax) -> Bool {
        withoutParentheses(expr).as(BooleanLiteralExprSyntax.self)?.literal.text == "false"
    }

    /// Whether an odd number of `!` operators stands between a node and the condition root.
    ///
    /// The boundary matters: without it the walk continues past the assertion into the
    /// enclosing statement and file, where any unrelated `!` would flip the answer.
    static func isNegated(_ node: Syntax, upTo boundary: SyntaxIdentifier) -> Bool {
        var negations = 0
        var current: Syntax? = node
        while let candidate = current {
            if let prefix = candidate.as(PrefixOperatorExprSyntax.self),
               prefix.operator.text == "!" {
                negations += 1
            }
            if candidate.id == boundary { break }
            current = candidate.parent
        }
        return negations % 2 == 1
    }

    /// An expression with its enclosing parentheses removed.
    ///
    /// Terminates on the first expression that is not a single unlabelled tuple element,
    /// which every expression eventually is.
    private static func withoutParentheses(_ expr: ExprSyntax) -> ExprSyntax {
        guard let tuple = expr.as(TupleExprSyntax.self),
              tuple.elements.count == 1,
              let only = tuple.elements.first,
              only.label == nil else {
            return expr
        }
        return withoutParentheses(only.expression)
    }

    /// An expression as source, without the trivia the parser attached to it.
    private static func rendered(_ expr: ExprSyntax) -> String {
        expr.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ambient-calendar-in-test

    /// A test reading its calendar from the machine it happens to run on.
    struct AmbientTimeSite {
        /// Which ambient reading was written.
        enum Reading {
            /// `Calendar.current`.
            case current
            /// `Calendar(identifier:)` — the calendar system is fixed, the time zone is not.
            case identifierInitialiser

            /// How the diagnostic names it.
            var describedAsWritten: String {
                switch self {
                case .current:
                    return "Calendar.current takes the calendar system, locale and time zone of whatever machine runs this test"
                case .identifierInitialiser:
                    return "Calendar(identifier:) fixes the calendar system and still inherits TimeZone.current, so its date arithmetic depends on where this test runs"
                }
            }
        }

        /// The reading found.
        let reading: Reading
    }

    /// Whether a reference to `Calendar` reads the ambient one.
    ///
    /// Both spellings are found from the same node — the `Calendar` reference itself — by
    /// asking what encloses it: a `.current` member access, or a call passing `identifier:`.
    ///
    /// ## Why `Calendar(identifier:)` counts
    ///
    /// It looks fixed, and that is the problem. Pinning the calendar *system* reads as
    /// diligence, so the site survives review — but the initialiser takes no time zone, the
    /// value carries `TimeZone.current`, and every component it computes still moves with the
    /// runner. A fiscal-year boundary asserted through one of these passes in Cupertino and
    /// fails in Auckland.
    ///
    /// ## Why `Date()` is not here
    ///
    /// It was, in the first draft, with a carve-out for two readings bracketing each other —
    /// `let before = Date(); …; let after = Date()` — which is correct code. That carve-out
    /// is a dataflow question and this is a syntax matcher, so it would have been wrong in
    /// both directions: flagging the correct bracketing tests, and missing every reading
    /// laundered through a helper. `Date()` was dropped rather than approximated.
    ///
    /// The boundary that remains is worth stating, because a neighbouring rule owns the other
    /// half: **a timestamp wants `Date()`; a calendar date wants a fixed calendar.**
    /// `hardcoded-date` owns the first and its suggested fix is literally *"Use `Date()`"*.
    /// A version of this rule that flagged `Date()` would have pulled against it on the same
    /// line.
    static func ambientCalendarReference(in node: DeclReferenceExprSyntax) -> AmbientTimeSite? {
        guard node.baseName.text == "Calendar" else { return nil }
        let reference = Syntax(node).id

        if let member = node.parent?.as(MemberAccessExprSyntax.self),
           member.base?.id == reference,
           member.declName.baseName.text == "current" {
            return AmbientTimeSite(reading: .current)
        }

        if let call = node.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == reference,
           call.arguments.contains(where: { $0.label?.text == "identifier" }) {
            return AmbientTimeSite(reading: .identifierInitialiser)
        }

        return nil
    }

    // MARK: - skipped-test-inventory

    /// A test that does not run, and the reason its author gave.
    struct Skip {
        /// How the test is prevented from running.
        enum Mechanism {
            /// A `.disabled(…)` trait on `@Test` or `@Suite`.
            case disabledTrait
            /// An `.enabled(if:)` or `.disabled(if:)` trait — runs only under a condition.
            case conditionalTrait
            /// `throw XCTSkip(…)`.
            case xctSkip
            /// An early `return` gated on an environment variable.
            case environmentGate

            /// How the diagnostic names it.
            var describedAsWritten: String {
                switch self {
                case .disabledTrait: return "disabled by a .disabled(…) trait"
                case .conditionalTrait: return "runs only when its condition holds"
                case .xctSkip: return "skipped by XCTSkip"
                case .environmentGate: return "skipped unless an environment variable is set"
                }
            }
        }

        /// The mechanism preventing the run.
        let mechanism: Mechanism
        /// The reason the author recorded, if they recorded one.
        let reason: String?
    }

    /// A skip declared as a trait among a declaration's attributes.
    ///
    /// Covers both spellings, because both mean the test does not run:
    ///
    /// - `.disabled("reason")` — off unconditionally.
    /// - `.enabled(if: cond, "reason")` / `.disabled(if: cond)` — off unless a condition
    ///   holds. In the corpus this is invariably an environment variable, so the test runs
    ///   for whoever exports it and for nobody else.
    ///
    /// The conditional form is the *correct* way to skip — the framework records it as a
    /// skip instead of counting a silent `return` as a pass, and it is what
    /// `unasserted-optional-unwrap` tells people to migrate to. Inventorying it is not a
    /// criticism of it. A suite where forty tests are gated behind `RUN_BENCHMARKS` is
    /// green every day while forty tests never execute, and the only defence against that
    /// becoming invisible is a line of output per gated test.
    ///
    /// Returns `nil` when nothing disables the declaration. A disabled test *without* a
    /// stated reason still returns a `Skip` — with `reason` nil — because the missing
    /// reason is itself the thing worth seeing.
    ///
    /// ## Known limit: a named trait hides from this
    ///
    /// The match is on the trait's spelling at the call site, so a project that wraps the
    /// condition in its own trait —
    /// `static var requiresBenchmarks: Self { .enabled(if: …) }`, then `@Test(.requiresBenchmarks)`
    /// — is not inventoried. Resolving that needs cross-file symbol resolution, which this
    /// rule does not have and is not worth acquiring for it: the wrapper is a *named,
    /// documented, greppable* declaration, which is the opposite of the silent skip this
    /// inventory exists to surface. The gap is recorded rather than closed.
    static func skipTrait(in attributes: AttributeListSyntax) -> Skip? {
        for attribute in attributes {
            guard let attr = attribute.as(AttributeSyntax.self),
                  let arguments = attr.arguments?.as(LabeledExprListSyntax.self) else {
                continue
            }
            for argument in arguments {
                guard let call = argument.expression.as(FunctionCallExprSyntax.self),
                      let member = call.calledExpression.as(MemberAccessExprSyntax.self) else {
                    continue
                }
                let trait = member.declName.baseName.text
                let isConditional = call.arguments.contains { $0.label?.text == "if" }

                switch (trait, isConditional) {
                case ("disabled", false):
                    return Skip(mechanism: .disabledTrait, reason: firstStringLiteral(in: call))
                case ("disabled", true), ("enabled", true):
                    return Skip(
                        mechanism: .conditionalTrait,
                        reason: firstStringLiteral(in: call) ?? conditionText(of: call))
                default:
                    continue
                }
            }
        }
        return nil
    }

    /// The `if:` condition rendered as source, for a conditional trait with no reason string.
    ///
    /// Without this the diagnostic would say only "runs only when its condition holds",
    /// which tells a reader nothing they can act on. `environment["RUN_BENCHMARKS"] != nil`
    /// tells them how to run it.
    private static func conditionText(of call: FunctionCallExprSyntax) -> String? {
        guard let condition = call.arguments.first(where: { $0.label?.text == "if" }) else {
            return nil
        }
        let rendered = condition.expression.description
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return rendered.isEmpty ? nil : rendered
    }

    /// Whether a guard is an environment gate — `guard …environment["X"] … else { return }`.
    ///
    /// Claimed by the inventory rather than by `unasserted-optional-unwrap`, even when it
    /// binds an optional. Both descriptions are true of
    /// `guard let _ = ProcessInfo.processInfo.environment["RUN_SLOW"] else { return }`, and
    /// only one of them is useful: this is a test its author chose not to run by default,
    /// which is a fact about the suite's inventory, not a defect in the test. Reporting it
    /// twice, once as a skip and once as an error, would make the error rule wrong in the
    /// one case where its shape is deliberate.
    static func isEnvironmentGate(_ node: GuardStmtSyntax) -> Bool {
        guard exitsByBareReturn(node.body) else { return false }
        let scan = EnvironmentReferenceScanner(viewMode: .sourceAccurate)
        for condition in node.conditions { scan.walk(condition) }
        return scan.found
    }

    /// The `XCTSkip` reason thrown by a statement, if it throws one.
    static func xctSkip(in node: ThrowStmtSyntax) -> Skip? {
        guard let call = node.expression.as(FunctionCallExprSyntax.self),
              call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "XCTSkip" else {
            return nil
        }
        return Skip(mechanism: .xctSkip, reason: firstStringLiteral(in: call))
    }

    /// The first simple string-literal argument of a call, with its quotes removed.
    ///
    /// Interpolated reasons return `nil` rather than a half-rendered string: a diagnostic
    /// quoting `"needs \(count) samples"` verbatim would be reporting source text as if it
    /// were a reason.
    private static func firstStringLiteral(in call: FunctionCallExprSyntax) -> String? {
        for argument in call.arguments {
            guard let literal = argument.expression.as(StringLiteralExprSyntax.self),
                  literal.segments.count == 1,
                  let segment = literal.segments.first?.as(StringSegmentSyntax.self) else {
                continue
            }
            return segment.content.text
        }
        return nil
    }

    /// Looks for a read of the process environment.
    private final class EnvironmentReferenceScanner: SyntaxVisitor {
        var found = false

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            if node.declName.baseName.text == "environment" {
                found = true
            }
            return .visitChildren
        }
    }

    // MARK: - unasserted-optional-unwrap

    /// Whether a `guard` inside a `@Test` makes the test pass silently when the bound
    /// value is `nil`.
    ///
    /// ```swift
    /// import Testing
    ///
    /// let seed: UInt64 = 42
    /// func streamUniforms(count: Int, seed: UInt64) throws -> [Double]? { nil }
    ///
    /// @Test func sampling() throws {
    ///     guard let samples = try streamUniforms(count: 100_000, seed: seed) else { return }
    ///     #expect(samples.count == 100_000)
    /// }
    /// ```
    ///
    /// When `streamUniforms` returns `nil`, the test returns having executed none of its
    /// assertions, and reports success. This is the shape that hid a GPU determinism test
    /// which ran entirely on the CPU for a year: a guard inside the optimizer made the
    /// GPU path unreachable, the guard took its silent exit, and the assertion that never
    /// ran was reported green every day.
    ///
    /// ## Why only optional bindings
    ///
    /// A `guard someCondition else { return }` is equally silent, and is deliberately not
    /// flagged here. Two reasons. It is usually a *platform or environment gate* —
    /// `guard #available(macOS 14, *)`, `guard ProcessInfo…environment["CI"] == nil` —
    /// which is a legitimate shape with an owner: the skipped-test inventory reports it,
    /// where it is visible as a skip rather than misfiled as a defect. And this rule ships
    /// at `error` severity, which only survives if it is unambiguous when it fires.
    ///
    /// The fix is `try #require(...)`, which fails loudly and prints what was `nil`.
    ///
    /// ## What "silent exit" has to mean
    ///
    /// Three shapes flagged by the first draft of this rule, across BusinessMath's 557
    /// test files, are correct code. Each narrowed the definition:
    ///
    /// - `else { continue }` skips one iteration of a loop. The test goes on to run its
    ///   assertions, so the exit is not the test's. Only a `return` counts.
    /// - `else { return false }` inside `contains { … }` returns from the *predicate*.
    ///   A `return` carrying a value is answering a question, not abandoning a test —
    ///   a `@Test` function returns `Void`.
    /// - `else { return true }` inside a helper `func` declared in the test body returns
    ///   from the helper. Whether the guard exits the *test* is a question about the
    ///   enclosing scope, which the caller answers; see `TestQualityVisitor`, which
    ///   suppresses this rule inside closures and nested function declarations.
    ///
    /// The first two are decided here. The third cannot be — a `GuardStmtSyntax` does not
    /// know what encloses it.
    ///
    /// - Parameter node: A `guard` statement appearing directly in a `@Test` function's
    ///   own scope — not inside a closure or nested function it contains.
    /// - Returns: `true` when the guard binds an optional and its `else` branch leaves the
    ///   test by a bare `return`, without recording a failure.
    static func isUnassertedOptionalUnwrap(_ node: GuardStmtSyntax) -> Bool {
        guard bindsAnOptional(node.conditions) else { return false }
        guard exitsByBareReturn(node.body) else { return false }
        return !reportsFailure(node.body)
    }

    /// Whether the block's final statement is `return` with no value.
    ///
    /// The last statement rather than the only one: `else { print("no GPU"); return }` is
    /// just as silent, and a body that logs before vanishing is if anything more likely to
    /// have been written deliberately.
    private static func exitsByBareReturn(_ block: CodeBlockSyntax) -> Bool {
        guard let last = block.statements.last?.item.as(ReturnStmtSyntax.self) else {
            return false
        }
        return last.expression == nil
    }

    /// Whether any condition in the list is an optional binding (`let x = …`).
    private static func bindsAnOptional(_ conditions: ConditionElementListSyntax) -> Bool {
        conditions.contains { element in
            if case .optionalBinding = element.condition { return true }
            return false
        }
    }

    /// Whether a block makes a test's failure observable.
    ///
    /// Anything that throws, records an issue, or asserts counts. The point is not to
    /// enumerate every failure API — it is that a block doing *none* of these is a silent
    /// exit, and a silent exit from a `@Test` is indistinguishable from a pass.
    private static func reportsFailure(_ block: CodeBlockSyntax) -> Bool {
        let scan = FailureReportScanner(viewMode: .sourceAccurate)
        scan.walk(block)
        return scan.found
    }

    /// Walks a block looking for any construct that makes a failure visible.
    private final class FailureReportScanner: SyntaxVisitor {
        var found = false

        override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }

        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            if node.macroName.text == "expect" || node.macroName.text == "require" {
                found = true
            }
            return .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            // `Issue.record(…)`. Matched on the token rather than on `base.description`,
            // which carries the node's leading trivia — including the newline that
            // `.whitespaces` does not trim.
            if node.declName.baseName.text == "record",
               node.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "Issue" {
                found = true
            }
            return .visitChildren
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            let name = node.baseName.text
            if name == "XCTFail" || name.hasPrefix("XCTAssert") {
                found = true
            }
            return .visitChildren
        }
    }
}
