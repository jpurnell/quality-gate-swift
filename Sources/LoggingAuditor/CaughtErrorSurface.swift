import Foundation
import SwiftSyntax

/// Whether a `catch` hands its error to whoever is waiting for it.
///
/// `logging.catch-without-logging` is about an error that *disappears*. A logger call and a
/// `throw` are two ways it does not. These are the others, and what they share is that each is
/// decided by following the **caught error's own name** — not by matching a type or a method
/// name, which is how this rule went wrong before:
///
/// 1. **Written to stderr.** `FileHandle.standardError.write(Data("…\(error)".utf8))`,
///    `fputs("…\(error)", stderr)`, `print(error, to: &standardError)`. For a pipe-filter
///    command-line tool that *is* the error report; there is no log to prefer.
/// 2. **Handed to a call, and then the process ends.** `print("failed: \(error)")` followed by
///    `exit(1)`, or `fatalError("\(error)")`. The body's last statement must be one that does
///    not return.
/// 3. **Carried by every exit.** `return "Invalid pattern: \(error.localizedDescription)"` —
///    the caller receives the error inside the value. *Every* exit: a body with one arm that
///    returns `nil`, one that falls off its end, or a `break` or `continue`, has a path on
///    which the error is gone, and that path is the one the rule is about.
///
/// What is deliberately still reported: `catch { exit(1) }`, which ends the process without
/// saying why; a fixed string to stderr, which says that something failed and not what; the
/// error printed to stdout by code that then carries on; and an error first copied into a
/// local and only then written out, which this does not follow.
enum CaughtErrorSurface {

    /// Calls that do not return.
    private static let neverReturning: Set<String> = [
        "exit", "_exit", "abort", "fatalError", "preconditionFailure",
    ]

    /// Identifiers that name the standard error stream.
    private static let stderrNames: Set<String> = ["stderr", "standardError"]

    /// Whether `clause` surfaces the error it caught.
    static func surfaces(_ clause: CatchClauseSyntax) -> Bool {
        let names = caughtNames(clause)
        guard !names.isEmpty else { return false }

        let scan = BodyScanner(errorNames: names, viewMode: .sourceAccurate)
        scan.walk(clause.body)

        if scan.writesTheErrorToStderr { return true }
        if scan.handsTheErrorToACall, endsWithoutReturning(clause.body.statements) { return true }

        guard !scan.returns.isEmpty, !scan.hasExitCarryingNothing else { return false }
        guard alwaysExits(clause.body.statements) else { return false }
        return scan.returns.allSatisfy { mentions(names, in: Syntax($0)) }
    }

    /// The names the caught error is bound to.
    ///
    /// A clause with no pattern binds the implicit `error`. A clause with a pattern binds what
    /// the pattern names — `catch let failure as DecodingError` — and nothing else: there is no
    /// implicit `error` in `catch is CancellationError`, so an `error` mentioned in that body
    /// is some other value and vouches for nothing.
    static func caughtNames(_ clause: CatchClauseSyntax) -> Set<String> {
        guard !clause.catchItems.isEmpty else { return ["error"] }
        var names: Set<String> = []
        for item in clause.catchItems {
            guard let pattern = item.pattern else { continue }
            for token in pattern.tokens(viewMode: .sourceAccurate) {
                if let identifier = token.parent?.as(IdentifierPatternSyntax.self) {
                    names.insert(identifier.identifier.text)
                }
            }
        }
        return names
    }

    /// Whether `node` refers to one of `names` as a value.
    ///
    /// As a value: `error`, `error.localizedDescription`, `"\(error)"`. Not as the *member*
    /// in `.error(.value)` or `Logger.error(…)` — that is somebody's case or method called
    /// `error`, and reading it as the caught error is the mistake this rule was repaired for
    /// once already.
    static func mentions(_ names: Set<String>, in node: Syntax) -> Bool {
        for token in node.tokens(viewMode: .sourceAccurate) {
            guard let reference = token.parent?.as(DeclReferenceExprSyntax.self),
                  names.contains(reference.baseName.text) else { continue }
            if let member = reference.parent?.as(MemberAccessExprSyntax.self),
               member.declName.id == reference.id {
                continue
            }
            return true
        }
        return false
    }

    /// The name a call is made by — `exit` in both `exit(1)` and `Foundation.exit(1)`.
    private static func calleeName(_ call: FunctionCallExprSyntax) -> String? {
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text
        }
        return call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    /// Whether the last statement of `statements` is a call that does not return.
    private static func endsWithoutReturning(_ statements: CodeBlockItemListSyntax) -> Bool {
        guard let last = statements.last else { return false }
        return isNeverReturningCall(last.item)
    }

    private static func isNeverReturningCall(_ item: CodeBlockItemSyntax.Item) -> Bool {
        var expression = item.as(ExprSyntax.self)
        if let statement = item.as(StmtSyntax.self)?.as(ExpressionStmtSyntax.self) {
            expression = statement.expression
        }
        guard let call = expression?.as(FunctionCallExprSyntax.self), let name = calleeName(call) else {
            return false
        }
        return neverReturning.contains(name)
    }

    /// Whether control cannot fall off the end of `statements`.
    ///
    /// Decided on the last statement alone: a `return`, a `throw`, a call that does not return,
    /// or an `if`/`else`, `switch` or `do`/`catch` every arm of which ends that way. Anything
    /// else — including a loop, which may run zero times — can fall through.
    static func alwaysExits(_ statements: CodeBlockItemListSyntax) -> Bool {
        guard let last = statements.last else { return false }
        let item = last.item
        if isNeverReturningCall(item) { return true }

        if let statement = item.as(StmtSyntax.self) {
            if statement.is(ReturnStmtSyntax.self) || statement.is(ThrowStmtSyntax.self) { return true }
            if let wrapped = statement.as(ExpressionStmtSyntax.self) {
                return expressionAlwaysExits(wrapped.expression)
            }
            if let doStatement = statement.as(DoStmtSyntax.self) {
                return alwaysExits(doStatement.body.statements)
                    && doStatement.catchClauses.allSatisfy { alwaysExits($0.body.statements) }
            }
            return false
        }
        if let expression = item.as(ExprSyntax.self) {
            return expressionAlwaysExits(expression)
        }
        return false
    }

    private static func expressionAlwaysExits(_ expression: ExprSyntax) -> Bool {
        if let conditional = expression.as(IfExprSyntax.self) {
            guard alwaysExits(conditional.body.statements), let elseBody = conditional.elseBody else {
                return false
            }
            switch elseBody {
            case .codeBlock(let block):
                return alwaysExits(block.statements)
            case .ifExpr(let nested):
                return expressionAlwaysExits(ExprSyntax(nested))
            }
        }
        if let switchExpression = expression.as(SwitchExprSyntax.self) {
            guard !switchExpression.cases.isEmpty else { return false }
            return switchExpression.cases.allSatisfy { element in
                guard let switchCase = element.as(SwitchCaseSyntax.self) else { return false }
                return alwaysExits(switchCase.statements)
            }
        }
        return false
    }

    /// Reads one catch body: where the caught error goes, and how the body leaves.
    ///
    /// A nested `catch` is skipped — its `error` is a different error, and it is judged on its
    /// own when the visitor reaches it. A closure is skipped too: what it does with the error
    /// happens later or never, and its `return` answers the closure, not the catch.
    private final class BodyScanner: SyntaxVisitor {
        let errorNames: Set<String>
        private(set) var writesTheErrorToStderr = false
        private(set) var handsTheErrorToACall = false
        private(set) var returns: [ExprSyntax] = []
        private(set) var hasExitCarryingNothing = false

        init(errorNames: Set<String>, viewMode: SyntaxTreeViewMode) {
            self.errorNames = errorNames
            super.init(viewMode: viewMode)
        }

        override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            if let value = node.expression {
                returns.append(value)
            } else {
                hasExitCarryingNothing = true
            }
            return .visitChildren
        }

        override func visit(_ node: BreakStmtSyntax) -> SyntaxVisitorContinueKind {
            hasExitCarryingNothing = true
            return .skipChildren
        }

        override func visit(_ node: ContinueStmtSyntax) -> SyntaxVisitorContinueKind {
            hasExitCarryingNothing = true
            return .skipChildren
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            guard CaughtErrorSurface.mentions(errorNames, in: Syntax(node.arguments)) else {
                return .visitChildren
            }
            handsTheErrorToACall = true
            if targetsStderr(node) { writesTheErrorToStderr = true }
            return .visitChildren
        }

        /// Whether a call writes to the standard error stream.
        ///
        /// Either the callee is reached through it — `FileHandle.standardError.write(…)` — or
        /// it is passed as an argument in its own right: `fputs(message, stderr)`,
        /// `print(…, to: &standardError)`. An argument that merely *contains* the name, such
        /// as a string mentioning it, is not that.
        private func targetsStderr(_ call: FunctionCallExprSyntax) -> Bool {
            if namesStderr(Syntax(call.calledExpression)) { return true }
            for argument in call.arguments {
                var expression = argument.expression
                if let inOut = expression.as(InOutExprSyntax.self) { expression = inOut.expression }
                guard expression.is(DeclReferenceExprSyntax.self) || expression.is(MemberAccessExprSyntax.self) else {
                    continue
                }
                if namesStderr(Syntax(expression)) { return true }
            }
            return false
        }

        private func namesStderr(_ node: Syntax) -> Bool {
            for token in node.tokens(viewMode: .sourceAccurate) {
                if case .identifier(let text) = token.tokenKind, CaughtErrorSurface.stderrNames.contains(text) {
                    return true
                }
            }
            return false
        }
    }
}
