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
}
