import SwiftSyntax

/// The `XCTAssert*` table: one XCTest call in, its Swift Testing equivalent out.
///
/// Every row keeps the claim the assertion made. `accuracy:` becomes an explicit tolerance with
/// the same bound; an exact `XCTAssertEqual` stays exact. Nothing here loosens a test, and a
/// call that does not fit a row is returned as `nil` and left exactly as written.
enum AssertionMapping {

    private static let comparisons: [String: String] = [
        "XCTAssertEqual": "==", "XCTAssertNotEqual": "!=",
        "XCTAssertGreaterThan": ">", "XCTAssertGreaterThanOrEqual": ">=",
        "XCTAssertLessThan": "<", "XCTAssertLessThanOrEqual": "<=",
        "XCTAssertIdentical": "===", "XCTAssertNotIdentical": "!==",
    ]

    /// The arguments of one call, sorted by role.
    private struct Arguments {
        var positional: [ExprSyntax] = []
        var accuracy: ExprSyntax?
        var forwardsSourceLocation = false

        init(_ list: LabeledExprListSyntax) {
            for argument in list {
                switch argument.label?.text {
                case nil: positional.append(argument.expression)
                case "accuracy": accuracy = argument.expression
                case "file", "line":
                    if argument.expression.trimmedDescription == argument.label?.text {
                        forwardsSourceLocation = true
                    }
                default: positional.append(argument.expression)
                }
            }
        }
    }

    /// The Swift Testing form of `call`, or `nil` if it is not an assertion this table maps.
    static func replacement(for call: FunctionCallExprSyntax, renderer: MigrationRenderer) -> String? {
        guard let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
              name.hasPrefix("XCT")
        else { return nil }
        let arguments = Arguments(call.arguments)
        let context = Context(renderer: renderer, arguments: arguments)

        if let op = comparisons[name] {
            return context.comparison(op, negatedTolerance: name == "XCTAssertNotEqual")
        }
        switch name {
        case "XCTAssert", "XCTAssertTrue": return context.truth(negated: false)
        case "XCTAssertFalse": return context.truth(negated: true)
        case "XCTAssertNil": return context.nilCheck("==")
        case "XCTAssertNotNil": return context.nilCheck("!=")
        case "XCTUnwrap": return context.unwrap()
        case "XCTFail": return context.fail()
        case "XCTAssertNoThrow": return context.noThrow()
        case "XCTAssertThrowsError": return context.throwsError(call.trailingClosure)
        default: return nil
        }
    }

    /// One call being mapped.
    private struct Context {
        let renderer: MigrationRenderer
        let arguments: Arguments

        private func text(_ expression: ExprSyntax) -> String { renderer.trimmed(expression) }

        /// `", message"` for the positional argument at `index`, if there is one.
        ///
        /// `Comment` is a string literal type, not a `String`, so a message held in a variable
        /// is interpolated.
        private func message(at index: Int) -> String {
            guard arguments.positional.indices.contains(index) else { return "" }
            let expression = arguments.positional[index]
            if expression.is(StringLiteralExprSyntax.self) { return ", " + text(expression) }
            return ", \"\\(" + text(expression) + ")\""
        }

        private var location: String {
            arguments.forwardsSourceLocation ? ", sourceLocation: sourceLocation" : ""
        }

        private func operand(_ expression: ExprSyntax) -> (effects: [String], text: String, core: ExprSyntax) {
            let stripped = Operand.strip(expression)
            return (stripped.effects, text(stripped.expression), stripped.expression)
        }

        func comparison(_ op: String, negatedTolerance: Bool) -> String? {
            guard arguments.positional.count >= 2 else { return nil }
            let lhs = operand(arguments.positional[0])
            let rhs = operand(arguments.positional[1])
            let prefix = Operand.prefix(lhs.effects, rhs.effects)
            let left = Operand.needsParenthesesInComparison(lhs.core) ? "(\(lhs.text))" : lhs.text
            let right = Operand.needsParenthesesInComparison(rhs.core) ? "(\(rhs.text))" : rhs.text

            if let accuracy = arguments.accuracy {
                let bound = Operand.needsParenthesesInComparison(accuracy) ? "(\(text(accuracy)))" : text(accuracy)
                let within = negatedTolerance ? ">" : "<="
                return "#expect(\(prefix)abs(\(left) - \(right)) \(within) \(bound)\(message(at: 2))\(location))"
            }
            return "#expect(\(prefix)\(left) \(op) \(right)\(message(at: 2))\(location))"
        }

        func truth(negated: Bool) -> String? {
            guard let first = arguments.positional.first else { return nil }
            let value = operand(first)
            let prefix = Operand.prefix(value.effects)
            let condition: String
            if negated {
                condition = Operand.isPostfixable(value.core) ? "!" + value.text : "!(\(value.text))"
            } else {
                condition = value.text
            }
            return "#expect(\(prefix)\(condition)\(message(at: 1))\(location))"
        }

        func nilCheck(_ op: String) -> String? {
            guard let first = arguments.positional.first else { return nil }
            let value = operand(first)
            let subject = Operand.needsParenthesesInComparison(value.core) ? "(\(value.text))" : value.text
            return "#expect(\(Operand.prefix(value.effects))\(subject) \(op) nil\(message(at: 1))\(location))"
        }

        /// `XCTUnwrap(f())` → `#require(try f())` when this file declares `f` as throwing.
        ///
        /// `try XCTUnwrap(…)` covered a throwing call inside its autoclosure. `#require`
        /// expands its argument into a closure the outer `try` does not reach, so the call
        /// needs its own. That can only be known for functions this file declares. A
        /// throwing call from elsewhere is a compile error with the fix in its message.
        func unwrap() -> String? {
            guard let first = arguments.positional.first else { return nil }
            var value = text(first)
            if !first.is(TryExprSyntax.self),
               let call = first.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               renderer.throwingFunctions.contains(callee.baseName.text) {
                value = "try " + value
            }
            return "#require(\(value)\(message(at: 1))\(location))"
        }

        func fail() -> String {
            guard let first = arguments.positional.first else { return "Issue.record(\(location.dropFirst(2)))" }
            let recorded = first.is(StringLiteralExprSyntax.self) ? text(first) : "\"\\(" + text(first) + ")\""
            return "Issue.record(\(recorded)\(location))"
        }

        func noThrow() -> String? {
            guard let first = arguments.positional.first else { return nil }
            let body = text(first)
            let awaited = first.description.contains("await") ? "await " : ""
            return "\(awaited)#expect(throws: Never.self\(message(at: 1))\(location)) { \(body) }"
        }

        /// `XCTAssertThrowsError(e) { error in … }` → `if let error = #expect(throws:, performing:) { … }`.
        ///
        /// A closure that inspects `$0` is given a name, and only `$0` at the closure's own
        /// level is respelled. A nested closure's `$0` is a different value.
        func throwsError(_ closure: ClosureExprSyntax?) -> String? {
            guard let first = arguments.positional.first else { return nil }
            let body = text(first)
            let awaited = first.description.contains("await") ? "await " : ""
            let head = "#expect(throws: (any Error).self\(message(at: 1))\(location)"
            guard let closure else { return "\(awaited)\(head)) { \(body) }" }

            let name = Self.parameterName(of: closure) ?? "error"
            let statements = renderer.renderStatements(
                of: closure, dollarZeroAs: Self.parameterName(of: closure) == nil ? name : nil)
            let closing = closure.rightBrace.leadingTrivia.description + "}"
            if name == "_" {
                return "if \(awaited)\(head), performing: { \(body) }) != nil {\(statements)\(closing)"
            }
            return "if let \(name) = \(awaited)\(head), performing: { \(body) }) {\(statements)\(closing)"
        }

        private static func parameterName(of closure: ClosureExprSyntax) -> String? {
            switch closure.signature?.parameterClause {
            case .simpleInput(let list): return list.first?.name.text
            case .parameterClause(let clause): return clause.parameters.first?.firstName.text
            case nil: return nil
            }
        }
    }
}
