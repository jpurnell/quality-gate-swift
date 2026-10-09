import SwiftSyntax

/// A skip written as the first statement of a test, restated as an `.enabled(if:)` trait.
///
/// `try XCTSkipUnless(hasCorpus, "private")` at the top of a test says the test does not apply
/// here, before the test has done anything. That is what a trait says, and Swift Testing
/// records it the same way: skipped, with the reason. A skip anywhere else is a different
/// statement. It may be a helper giving up on a value, which is a failure, so it is left for a
/// person (see ``MigrationResidue``).
///
/// A trait is evaluated before the suite exists. A condition that reads the suite's stored
/// state, or `self`, cannot move there, and is not converted.
enum SkipTrait {

    /// One leading skip and what replaces it.
    struct Conversion {
        /// The trait, as written inside `@Test(…)`.
        let trait: String
        /// The statement the trait replaces.
        let statement: SyntaxIdentifier
        /// The `XCTSkip…` reference inside it, which is now accounted for.
        let reference: SyntaxIdentifier
    }

    /// The trait for `function`'s first statement, if that statement is a skip a trait can state.
    ///
    /// - Parameters:
    ///   - function: A test method.
    ///   - instanceMembers: Names the suite declares as instance members. A condition naming
    ///     one cannot be evaluated before the suite is created.
    static func conversion(for function: FunctionDeclSyntax, instanceMembers: Set<String>) -> Conversion? {
        guard let first = function.body?.statements.first,
              let skip = skip(in: first.item),
              isEvaluableBeforeTheSuiteExists(skip.condition, instanceMembers: instanceMembers),
              skip.message.map({ isEvaluableBeforeTheSuiteExists($0, instanceMembers: instanceMembers) }) ?? true
        else { return nil }

        let condition = skip.enabledWhenTrue ? skip.condition.trimmedDescription : negated(skip.condition)
        var trait = ".enabled(if: \(condition)"
        if let message = skip.message {
            trait += ", " + MessageText.comment(message, text: message.trimmedDescription)
        }
        return Conversion(trait: trait + ")", statement: first.id, reference: skip.reference)
    }

    /// The parts of one skip statement.
    private struct Skip {
        let condition: ExprSyntax
        /// `true` when the test runs if the condition holds (`XCTSkipUnless`, `guard`).
        let enabledWhenTrue: Bool
        let message: ExprSyntax?
        let reference: SyntaxIdentifier
    }

    private static func skip(in item: CodeBlockItemSyntax.Item) -> Skip? {
        switch item {
        case .expr(let expression):
            if let ifExpr = expression.as(IfExprSyntax.self) { return skip(ifExpr) }
            return skipCall(expression)
        case .stmt(let statement):
            if let guardStmt = statement.as(GuardStmtSyntax.self) {
                guard let condition = soleCondition(guardStmt.conditions),
                      let thrown = thrownSkip(guardStmt.body)
                else { return nil }
                return Skip(condition: condition, enabledWhenTrue: true, message: thrown.message, reference: thrown.reference)
            }
            if let expressionStmt = statement.as(ExpressionStmtSyntax.self) {
                if let ifExpr = expressionStmt.expression.as(IfExprSyntax.self) { return skip(ifExpr) }
                return skipCall(expressionStmt.expression)
            }
            return nil
        case .decl:
            return nil
        }
    }

    /// `try XCTSkipIf(condition, "why")` or `try XCTSkipUnless(condition, "why")`.
    private static func skipCall(_ expression: ExprSyntax) -> Skip? {
        let stripped = Operand.strip(expression)
        guard stripped.effects == ["try"],
              let call = stripped.expression.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
              callee.baseName.text == "XCTSkipIf" || callee.baseName.text == "XCTSkipUnless",
              call.trailingClosure == nil,
              call.arguments.allSatisfy({ $0.label == nil }),
              (1...2).contains(call.arguments.count),
              let condition = call.arguments.first?.expression
        else { return nil }
        let message = call.arguments.count == 2 ? call.arguments.last?.expression : nil
        return Skip(
            condition: condition, enabledWhenTrue: callee.baseName.text == "XCTSkipUnless",
            message: message, reference: callee.id)
    }

    /// `if condition { throw XCTSkip("why") }`, with no `else`.
    private static func skip(_ ifExpr: IfExprSyntax) -> Skip? {
        guard ifExpr.elseBody == nil,
              let condition = soleCondition(ifExpr.conditions),
              let thrown = thrownSkip(ifExpr.body)
        else { return nil }
        return Skip(condition: condition, enabledWhenTrue: false, message: thrown.message, reference: thrown.reference)
    }

    private static func soleCondition(_ conditions: ConditionElementListSyntax) -> ExprSyntax? {
        guard conditions.count == 1, case .expression(let expression)? = conditions.first?.condition else {
            return nil
        }
        return expression
    }

    /// A block whose only statement is `throw XCTSkip()` or `throw XCTSkip("why")`.
    private static func thrownSkip(_ block: CodeBlockSyntax) -> (message: ExprSyntax?, reference: SyntaxIdentifier)? {
        guard block.statements.count == 1,
              let thrown = block.statements.first?.item.as(ThrowStmtSyntax.self),
              let call = thrown.expression.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
              callee.baseName.text == "XCTSkip",
              call.trailingClosure == nil,
              call.arguments.count <= 1,
              call.arguments.allSatisfy({ $0.label == nil })
        else { return nil }
        return (call.arguments.first?.expression, callee.id)
    }

    private static func negated(_ condition: ExprSyntax) -> String {
        if let prefix = condition.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
            return prefix.expression.trimmedDescription
        }
        let text = condition.trimmedDescription
        return Operand.isPostfixable(condition) ? "!" + text : "!(\(text))"
    }

    private static func isEvaluableBeforeTheSuiteExists(_ expression: ExprSyntax, instanceMembers: Set<String>) -> Bool {
        let scan = InstanceStateScanner(instanceMembers: instanceMembers)
        scan.walk(expression)
        return !scan.found
    }

    /// Looks for anything that needs an instance of the suite, or an effect a trait's
    /// autoclosure does not carry.
    private final class InstanceStateScanner: SyntaxVisitor {
        let instanceMembers: Set<String>
        var found = false

        init(instanceMembers: Set<String>) {
            self.instanceMembers = instanceMembers
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if node.isMemberName { return .visitChildren }
            let name = node.baseName.text
            if name == "self" || name == "super" || instanceMembers.contains(name) { found = true }
            return .visitChildren
        }

        override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }

        override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
    }
}

extension DeclReferenceExprSyntax {
    /// Whether this is the `name` in `base.name`, which refers to a member, not to a name in scope.
    var isMemberName: Bool {
        guard let member = parent?.as(MemberAccessExprSyntax.self) else { return false }
        return member.declName.id == id
    }
}
