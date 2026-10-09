import SwiftSyntax

/// How an argument of an `XCTAssert*` call is written once it is an operand in `#expect`.
///
/// `XCTAssertEqual(flag ? 1 : 2, 1)` compared the ternary's value. Written naively,
/// `#expect(flag ? 1 : 2 == 1)` parses as `flag ? 1 : (2 == 1)`, which is a different test that
/// still compiles. Parentheses are added from the shape of the syntax node, not by scanning
/// the text for operator characters.
enum Operand {

    /// An operand with its leading `try`/`await` removed and recorded.
    struct Stripped {
        /// `try`, `try?`, `await`, in source order.
        let effects: [String]
        /// The expression underneath them.
        let expression: ExprSyntax
    }

    /// Peels `try` and `await` off the front of `expression`.
    ///
    /// They are hoisted to the front of the whole `#expect` condition. `a == try b` does not
    /// compile, since `try` may not appear right of a non-assignment operator, and
    /// `try a == b` covers both sides.
    static func strip(_ expression: ExprSyntax) -> Stripped {
        var effects: [String] = []
        var core = expression
        while let (effect, inner) = peel(core) {
            effects.append(effect)
            core = inner
        }
        return Stripped(effects: effects, expression: core)
    }

    /// The outermost `try` or `await` on `expression` and what it applies to, if it has one.
    private static func peel(_ expression: ExprSyntax) -> (effect: String, inner: ExprSyntax)? {
        if let tryExpr = expression.as(TryExprSyntax.self) {
            return (tryExpr.tryKeyword.text + (tryExpr.questionOrExclamationMark?.text ?? ""), tryExpr.expression)
        }
        if let awaitExpr = expression.as(AwaitExprSyntax.self) {
            return ("await", awaitExpr.expression)
        }
        return nil
    }

    /// Merges effect lists into one prefix (`"try await "`), each effect once, in Swift's order.
    static func prefix(_ lists: [String]...) -> String {
        let all = lists.flatMap { $0 }
        var ordered: [String] = []
        if let tryForm = all.first(where: { $0.hasPrefix("try") }) { ordered.append(tryForm) }
        if all.contains("await") { ordered.append("await") }
        return ordered.isEmpty ? "" : ordered.joined(separator: " ") + " "
    }

    /// Whether `expression`, as one side of `==` or `<`, needs parentheses to keep its meaning.
    ///
    /// Casts bind tighter than comparison, so `error as? E == .bad` is left as written.
    /// Anything else with an operator at its top level is parenthesised. Arithmetic would
    /// also bind tighter, but `(a + b) == c` reads as the claim that was made.
    static func needsParenthesesInComparison(_ expression: ExprSyntax) -> Bool {
        if expression.is(TernaryExprSyntax.self) || expression.is(ClosureExprSyntax.self)
            || expression.is(InfixOperatorExprSyntax.self) {
            return true
        }
        guard let sequence = expression.as(SequenceExprSyntax.self) else { return false }
        return sequence.elements.contains { element in
            element.is(BinaryOperatorExprSyntax.self)
                || element.is(UnresolvedTernaryExprSyntax.self)
                || element.is(AssignmentExprSyntax.self)
        }
    }

    /// Whether `expression` can take a postfix (`.member`, a leading `!`) without parentheses.
    static func isPostfixable(_ expression: ExprSyntax) -> Bool {
        expression.is(DeclReferenceExprSyntax.self)
            || expression.is(MemberAccessExprSyntax.self)
            || expression.is(FunctionCallExprSyntax.self)
            || expression.is(SubscriptCallExprSyntax.self)
            || expression.is(OptionalChainingExprSyntax.self)
            || expression.is(ForceUnwrapExprSyntax.self)
            || expression.is(TupleExprSyntax.self)
            || expression.is(IntegerLiteralExprSyntax.self)
            || expression.is(FloatLiteralExprSyntax.self)
            || expression.is(StringLiteralExprSyntax.self)
            || expression.is(BooleanLiteralExprSyntax.self)
            || expression.is(ArrayExprSyntax.self)
            || expression.is(DictionaryExprSyntax.self)
            || expression.is(MacroExpansionExprSyntax.self)
    }

    /// `text` as the receiver of a method call, parenthesised when `expression` needs it.
    ///
    /// `-1.5.isEqual(to: x)` negates the result of the call, so a prefix operator is wrapped.
    static func receiver(_ expression: ExprSyntax, text: String) -> String {
        isPostfixable(expression) ? text : "(\(text))"
    }

    /// The trimmed source of `expression` as a method receiver.
    static func receiver(_ expression: ExprSyntax) -> String {
        receiver(expression, text: expression.trimmedDescription)
    }

    // MARK: - What an assertion macro cannot hold

    /// `optional ?? literal`, and the node to replace with the unwrapped value.
    struct CoalescedSite {
        /// The value left of `??`.
        let optional: ExprSyntax
        /// Whether the fallback is `true` or `false`, which makes the optional a `Bool?`.
        let isBoolean: Bool
        /// The whole `a ?? b`, with its parentheses when it has them.
        let whole: Syntax
    }

    /// The fallback in `expression`, when it is the operand itself or the parenthesised start
    /// of it: `x ?? ""`, `(x ?? "").count`, `(x ?? []).contains(y)`.
    ///
    /// Only a literal fallback counts, by the same test `coalesced-assertion` applies. A
    /// computed fallback is a value the test chose, and stays.
    static func coalescedFallback(in expression: ExprSyntax) -> CoalescedSite? {
        if let found = fallbackSubject(expression) {
            return CoalescedSite(optional: found.optional, isBoolean: found.isBoolean, whole: Syntax(expression))
        }
        var spine: ExprSyntax? = expression
        while let node = spine {
            if let tuple = node.as(TupleExprSyntax.self) {
                guard tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil,
                      let found = fallbackSubject(only.expression)
                else { return nil }
                return CoalescedSite(optional: found.optional, isBoolean: found.isBoolean, whole: Syntax(tuple))
            }
            spine = receiverOf(node)
        }
        return nil
    }

    private static func fallbackSubject(_ expression: ExprSyntax) -> (optional: ExprSyntax, isBoolean: Bool)? {
        guard let sequence = expression.as(SequenceExprSyntax.self), sequence.elements.count == 3 else {
            return nil
        }
        let elements = Array(sequence.elements)
        guard elements[1].as(BinaryOperatorExprSyntax.self)?.operator.text == "??",
              SemanticTestRules.fabricatedFallback(elements[2]) != nil
        else { return nil }
        return (elements[0], elements[2].is(BooleanLiteralExprSyntax.self))
    }

    /// What `expression` is a member, call, subscript or unwrap of, if it is one.
    private static func receiverOf(_ expression: ExprSyntax) -> ExprSyntax? {
        if let member = expression.as(MemberAccessExprSyntax.self) { return member.base }
        if let call = expression.as(FunctionCallExprSyntax.self) { return call.calledExpression }
        if let subscripted = expression.as(SubscriptCallExprSyntax.self) { return subscripted.calledExpression }
        if let chained = expression.as(OptionalChainingExprSyntax.self) { return chained.expression }
        if let forced = expression.as(ForceUnwrapExprSyntax.self) { return forced.expression }
        return nil
    }

    /// Whether `expression` calls a method on a local for which `isMutable` holds.
    ///
    /// Syntax cannot say whether `q.next()` is mutating. It can say `q` was declared `var`,
    /// and a `var` nothing mutates is a compiler warning, so a method called on one usually
    /// does. Binding a result that did not need it changes nothing.
    static func callsMethodOnLocal(_ expression: ExprSyntax, where isMutable: (String) -> Bool) -> Bool {
        let scan = CallScanner(viewMode: .sourceAccurate)
        scan.walk(expression)
        return scan.receivers.contains(where: isMutable)
    }

    /// Whether `expression` calls anything, outside a closure.
    static func containsCall(_ expression: ExprSyntax) -> Bool {
        let scan = CallScanner(viewMode: .sourceAccurate)
        scan.walk(expression)
        return scan.calls > 0
    }

    /// Whether the only calls in `expression` are `XCTUnwrap`, so that once those are bound
    /// elsewhere a `try` in front of it covers nothing.
    static func throwsOnlyByUnwrapping(_ expression: ExprSyntax) -> Bool {
        let scan = CallScanner(viewMode: .sourceAccurate)
        scan.walk(expression)
        return scan.unwraps > 0 && scan.calls == 0
    }

    /// Whether `expression` holds a closure that uses optional chaining.
    static func containsOptionalChainingInClosure(_ expression: ExprSyntax) -> Bool {
        let scan = ChainedClosureScanner(viewMode: .sourceAccurate)
        scan.walk(expression)
        return scan.found
    }

    /// Whether the nearest `try` around `node`, within its statement, is a plain one.
    ///
    /// Under `try?` a failed unwrap produced `nil` and the test carried on. Bound ahead as
    /// `try #require`, it would stop the test, so that unwrap is left where it is.
    static func isCoveredByPlainTry(_ node: Syntax) -> Bool {
        var current = node.parent
        while let candidate = current {
            if let tryExpr = candidate.as(TryExprSyntax.self) {
                return tryExpr.questionOrExclamationMark == nil
            }
            if candidate.is(CodeBlockItemSyntax.self) || candidate.is(ClosureExprSyntax.self) { return false }
            current = candidate.parent
        }
        return false
    }

    /// Whether `call` is the last statement of a function that returns nothing, where leaving
    /// an `if` body by `return` and leaving a closure by `return` come to the same thing.
    static func isLastStatementOfVoidFunction(_ call: FunctionCallExprSyntax) -> Bool {
        var statement = Syntax(call).parent
        if statement?.is(ExpressionStmtSyntax.self) == true { statement = statement?.parent }
        guard let item = statement?.as(CodeBlockItemSyntax.self),
              let list = item.parent?.as(CodeBlockItemListSyntax.self), list.last?.id == item.id,
              let function = list.parent?.parent?.as(FunctionDeclSyntax.self)
        else { return false }
        return function.signature.returnClause == nil
    }

    /// Counts the calls in an expression, outside closures and outside `XCTUnwrap(…)`.
    private final class CallScanner: SyntaxVisitor {
        /// Calls other than `XCTUnwrap`.
        var calls = 0
        var unwraps = 0
        /// The name each method call's receiver chain starts from: `q` in `q.items[0].next()`.
        var receivers: [String] = []

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            if node.calledExpression.trimmedDescription == "XCTUnwrap" {
                unwraps += 1
                return .skipChildren
            }
            calls += 1
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self), var root = member.base {
                while let receiver = Operand.receiverOf(root), !root.is(FunctionCallExprSyntax.self) {
                    root = receiver
                }
                if let reference = root.as(DeclReferenceExprSyntax.self) {
                    receivers.append(reference.baseName.text)
                }
            }
            return .visitChildren
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    }

    /// Looks for `?.` inside any closure.
    private final class ChainedClosureScanner: SyntaxVisitor {
        var found = false
        private var closureDepth = 0

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            closureDepth += 1
            return .visitChildren
        }

        override func visitPost(_ node: ClosureExprSyntax) {
            closureDepth -= 1
        }

        override func visit(_ node: OptionalChainingExprSyntax) -> SyntaxVisitorContinueKind {
            if closureDepth > 0 { found = true }
            return .visitChildren
        }
    }
}
