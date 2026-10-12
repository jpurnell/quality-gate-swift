import SwiftSyntax

/// `do { try f(); XCTFail("should throw") } catch is E { }` → `#expect(throws: E.self) { try f() }`.
///
/// XCTest had no way to say "this throws an `E`" for async code, so tests said it by hand: run
/// the call, fail if execution gets past it, and catch the error that was wanted. Converted
/// statement by statement that leaves a test whose only checks are `Issue.record`, with no
/// `#expect` or `#require` anywhere, which `missing-assertion` reports. SummerJams had one.
///
/// Only the shape that states exactly one claim is rewritten: the body ends in `XCTFail`, the
/// wanted error is caught and ignored, and any other error fails. A `catch` that binds the
/// error and asserts on it already converts to an `#expect` inside the `catch`, and is left.
enum ExpectedThrow {

    /// The `#expect(throws:)` form of `node`, or `nil` when it is any other `do`.
    static func replacement(for node: DoStmtSyntax, renderer: MigrationRenderer) -> String? {
        let statements = Array(node.body.statements)
        guard statements.count >= 2, let last = statements.last,
              let failure = failure(in: last.item),
              let expected = expectedError(node.catchClauses),
              !statements.dropLast().contains(where: { LeavesEarly.found(in: Syntax($0)) })
        else { return nil }

        let kept = statements.dropLast()
        let awaited = kept.contains { ContainsAwait.found(in: Syntax($0)) } ? "await " : ""
        var comment = ""
        if let message = failure.arguments.first(where: { $0.label == nil })?.expression {
            comment = ", " + MessageText.comment(message, text: renderer.trimmed(message))
        }
        let body = renderer.throwingScope { kept.map { renderer.render(Syntax($0)) }.joined() }
        return "\(awaited)#expect(throws: \(expected)\(comment)) {" + body
            + node.body.rightBrace.leadingTrivia.description + "}"
    }

    /// The `XCTFail(…)` call that `item` consists of, if it is one.
    private static func failure(in item: CodeBlockItemSyntax.Item) -> FunctionCallExprSyntax? {
        let expression: ExprSyntax?
        switch item {
        case .expr(let written): expression = written
        case .stmt(let statement): expression = statement.as(ExpressionStmtSyntax.self)?.expression
        case .decl: expression = nil
        }
        guard let call = expression?.as(FunctionCallExprSyntax.self),
              call.calledExpression.trimmedDescription == "XCTFail"
        else { return nil }
        return call
    }

    /// The error type the `catch` clauses accept in silence, as written for `throws:`.
    ///
    /// Either one empty `catch`, which accepts anything, or an empty `catch is E` followed at
    /// most by a `catch` that does nothing but fail.
    private static func expectedError(_ clauses: CatchClauseListSyntax) -> String? {
        let all = Array(clauses)
        guard let first = all.first, first.body.statements.isEmpty else { return nil }

        if first.catchItems.isEmpty {
            return all.count == 1 ? "(any Error).self" : nil
        }
        guard first.catchItems.count == 1, let item = first.catchItems.first, item.whereClause == nil,
              let type = caughtType(item.pattern)
        else { return nil }
        switch all.count {
        case 1:
            return type + ".self"
        case 2:
            let fallback = all[1]
            guard fallback.catchItems.isEmpty, fallback.body.statements.count == 1,
                  let only = fallback.body.statements.first, failure(in: only.item) != nil
            else { return nil }
            return type + ".self"
        default:
            return nil
        }
    }

    /// `E` in `catch is E`.
    private static func caughtType(_ pattern: PatternSyntax?) -> String? {
        if let isType = pattern?.as(IsTypePatternSyntax.self) {
            return isType.type.trimmedDescription
        }
        // Older parsers spell the same clause as an expression pattern holding `is E`.
        if let expression = pattern?.as(ExpressionPatternSyntax.self)?.expression,
           let sequence = expression.as(SequenceExprSyntax.self), sequence.elements.count == 2,
           sequence.elements.first?.is(UnresolvedIsExprSyntax.self) == true,
           let type = sequence.elements.last?.as(TypeExprSyntax.self) {
            return type.type.trimmedDescription
        }
        return nil
    }

    /// Finds `return`, `break`, `continue` or `throw` outside any nested closure or function.
    ///
    /// Inside `#expect(throws:) { … }` each of those would leave the closure, not the test.
    private final class LeavesEarly: SyntaxVisitor {
        private var result = false

        static func found(in node: Syntax) -> Bool {
            let visitor = LeavesEarly(viewMode: .sourceAccurate)
            visitor.walk(node)
            return visitor.result
        }

        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind { stop() }
        override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind { stop() }
        override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind { stop() }
        override func visit(_ node: ThrowStmtSyntax) -> SyntaxVisitorContinueKind { stop() }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

        private func stop() -> SyntaxVisitorContinueKind {
            result = true
            return .skipChildren
        }
    }
}

/// Finds an `await` outside any nested closure or function.
final class ContainsAwait: SyntaxVisitor {
    private var result = false

    /// Whether `node` awaits anything at its own level.
    static func found(in node: Syntax) -> Bool {
        let visitor = ContainsAwait(viewMode: .sourceAccurate)
        visitor.walk(node)
        return visitor.result
    }

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
        result = true
        return .skipChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}
