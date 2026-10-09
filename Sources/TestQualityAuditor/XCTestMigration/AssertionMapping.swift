import SwiftSyntax

/// The `XCTAssert*` table: one XCTest call in, its Swift Testing equivalent out.
///
/// Every row keeps the claim the assertion made. `accuracy:` becomes an explicit tolerance with
/// the same bound; an exact `XCTAssertEqual` stays exact. Nothing here loosens a test, and a
/// call that does not fit a row is returned as `nil` and left exactly as written.
///
/// Two rows are deliberately stricter than what they replace, because the looser form is one
/// this gate reports:
/// - `XCTAssertNotNil(x)` is `try #require(x)`, not `#expect(x != nil)` (`weak-assertion`).
/// - An operand `x ?? ""` is `try #require(x)` bound first (`coalesced-assertion`): a missing
///   value now fails instead of being compared as if it were an empty one.
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
        let context = Context(renderer: renderer, call: call, arguments: Arguments(call.arguments))

        if let op = comparisons[name] {
            return context.comparison(op, negatedTolerance: name == "XCTAssertNotEqual")
        }
        switch name {
        case "XCTAssert", "XCTAssertTrue": return context.truth(negated: false)
        case "XCTAssertFalse": return context.truth(negated: true)
        case "XCTAssertNil": return context.isNil()
        case "XCTAssertNotNil": return context.required()
        case "XCTUnwrap": return context.unwrap()
        case "XCTFail": return context.fail()
        case "XCTAssertNoThrow": return context.noThrow()
        case "XCTAssertThrowsError": return context.throwsError()
        default: return nil
        }
    }

    /// The closure or function `XCTAssertThrowsError` hands the thrown error to, wherever it
    /// was written: after the call, or as its last argument.
    static func errorHandler(of call: FunctionCallExprSyntax) -> ExprSyntax? {
        if let trailing = call.trailingClosure { return ExprSyntax(trailing) }
        let unlabelled = call.arguments.filter { $0.label == nil }.map(\.expression)
        guard let last = unlabelled.last, unlabelled.count >= 2 else { return nil }
        if last.is(ClosureExprSyntax.self) { return last }
        // (expression, message, handler): only a third argument can be a handler held by name.
        return unlabelled.count == 3 ? last : nil
    }

    /// Whether `reference` is the error an `XCTAssertThrowsError` closure receives.
    ///
    /// That value is an `any Error`, never optional, so a nil check on it cannot fail.
    static func isThrownErrorParameter(_ reference: DeclReferenceExprSyntax) -> Bool {
        var current = Syntax(reference).parent
        while let node = current {
            if node.is(FunctionDeclSyntax.self) { return false }
            if let closure = node.as(ClosureExprSyntax.self) {
                guard let call = enclosingCall(of: closure),
                      call.calledExpression.trimmedDescription == "XCTAssertThrowsError",
                      errorHandler(of: call)?.id == closure.id
                else { return false }
                return reference.baseName.text == (parameterName(of: closure) ?? "$0")
            }
            current = node.parent
        }
        return false
    }

    private static func enclosingCall(of closure: ClosureExprSyntax) -> FunctionCallExprSyntax? {
        if let call = closure.parent?.as(FunctionCallExprSyntax.self) { return call }
        return closure.parent?.parent?.parent?.as(FunctionCallExprSyntax.self)
    }

    static func parameterName(of closure: ClosureExprSyntax) -> String? {
        switch closure.signature?.parameterClause {
        case .simpleInput(let list): return list.first?.name.text
        case .parameterClause(let clause): return clause.parameters.first?.firstName.text
        case nil: return nil
        }
    }

    /// One operand of an assertion, as it will be written.
    private struct Written {
        /// `try`, `await` still to be hoisted to the front of the condition.
        var effects: [String]
        var text: String
        let core: ExprSyntax
        /// Whether the value was bound ahead of the assertion, leaving only its name here.
        var isBound = false

        var needsParentheses: Bool { !isBound && Operand.needsParenthesesInComparison(core) }
        var isPostfixable: Bool { isBound || Operand.isPostfixable(core) }
    }

    /// One call being mapped.
    private struct Context {
        let renderer: MigrationRenderer
        let call: FunctionCallExprSyntax
        let arguments: Arguments

        private func text(_ expression: ExprSyntax) -> String { renderer.trimmed(expression) }

        /// `", message"` for the positional argument at `index`, if there is one.
        private func message(at index: Int) -> String {
            guard arguments.positional.indices.contains(index) else { return "" }
            let expression = arguments.positional[index]
            return ", " + MessageText.comment(expression, text: text(expression))
        }

        private var location: String {
            arguments.forwardsSourceLocation ? ", sourceLocation: sourceLocation" : ""
        }

        // MARK: Operands

        /// The operands at `indices`, written for an `#expect` condition.
        ///
        /// - Parameter isWholeCondition: Whether the one operand is all the macro is given,
        ///   which is the case the macro expands differently (see ``boundClosureResult(_:)``).
        private func expected(_ indices: Range<Int>, isWholeCondition: Bool = false) -> [Written] {
            renderer.withinMacro(requiring: false) {
                bindingMutations(indices.map {
                    operand(arguments.positional[$0], isWholeCondition: isWholeCondition)
                })
            }
        }

        private func operand(_ expression: ExprSyntax, isWholeCondition: Bool) -> Written {
            let stripped = Operand.strip(expression)
            if let bound = requiredInsteadOfCoalesced(stripped.expression) {
                return Written(effects: stripped.effects, text: bound, core: stripped.expression, isBound: true)
            }
            if isWholeCondition, let bound = boundClosureResult(stripped.expression) {
                return Written(effects: stripped.effects, text: bound, core: stripped.expression, isBound: true)
            }
            let written = text(stripped.expression)
            var effects = stripped.effects
            // `try XCTUnwrap(x).count`: once the unwrap is bound on the line before, nothing
            // left here throws, and the compiler warns about a `try` that covers nothing.
            if Operand.throwsOnlyByUnwrapping(stripped.expression), !written.contains("#require(") {
                effects.removeAll { $0 == "try" }
            }
            return Written(effects: effects, text: written, core: stripped.expression)
        }

        /// `x ?? ""` → `let x = try #require(x)` on the line before, and the name here.
        ///
        /// The gate reports the fallback as `coalesced-assertion`: with it, a missing value is
        /// asserted on as though it were an empty one.
        private func requiredInsteadOfCoalesced(_ expression: ExprSyntax) -> String? {
            guard let site = Operand.coalescedFallback(in: expression) else { return nil }
            let subject = "An assertion on `\(site.whole.trimmedDescription)`"
            guard renderer.requireThrows(for: subject, at: Syntax(call)) else { return nil }
            // `#require` has one form that unwraps and one that checks a `Bool`. Handed a
            // `Bool?` it cannot tell which was meant and says so in a warning; the cast is how
            // Swift Testing asks to be told.
            let unwrapped = "try #require(\(text(site.optional))\(site.isBoolean ? " as Bool?" : ""))"
            guard let name = renderer.bind(unwrapped, named: HoistedName.base(for: site.optional), from: site.whole) else {
                renderer.decline("\(subject): the fallback makes a missing value pass as an empty one, which the gate reports as coalesced-assertion. The value cannot be unwrapped ahead of this statement, because the statement does not always evaluate it. Unwrap it where the test first needs it.", at: Syntax(call))
                return nil
            }
            if site.whole.id == Syntax(expression).id { return name }
            renderer.substitute(site.whole, with: name)
            return nil
        }

        /// Binds each operand that calls a method on a `var` local, and every call before it.
        ///
        /// `#expect(q.next())` does not compile when `next()` is mutating: the macro evaluates
        /// its operand through an immutable capture. Binding the earlier calls too keeps the
        /// order they ran in.
        private func bindingMutations(_ operands: [Written]) -> [Written] {
            guard let last = operands.lastIndex(where: {
                !$0.isBound && Operand.callsMethodOnLocal($0.core, where: renderer.isMutableLocal)
            }) else { return operands }
            var bound = operands
            for index in 0...last where !bound[index].isBound {
                guard index == last || Operand.containsCall(bound[index].core) else { continue }
                let value = Operand.prefix(bound[index].effects) + bound[index].text
                guard let name = renderer.bind(value, named: HoistedName.base(for: bound[index].core), from: Syntax(bound[index].core)) else {
                    renderer.decline("`\(bound[index].core.trimmedDescription)` inside an assertion: a mutating call does not compile inside #expect, and its result cannot be bound ahead of this statement, because the statement does not always evaluate it. Bind the result to a `let` first.", at: Syntax(call))
                    return operands
                }
                bound[index].text = name
                bound[index].effects = []
                bound[index].isBound = true
            }
            return bound
        }

        /// `xs.map { $0?.a }.isEmpty` → `let mapResult = xs.map { $0?.a }` on the line before,
        /// and `mapResult.isEmpty` here.
        ///
        /// A condition that is a property access is expanded into a separate read of that
        /// property. The macro sees a `?` somewhere in the base, takes the base for an optional
        /// chain, and writes the read as `$0?.isEmpty`, which does not compile on an array.
        /// BusinessMathExcel had `XCTUnwrap(cells.compactMap { sheet.cell(at: $0)?.formulaAST }.first)`.
        private func boundClosureResult(_ expression: ExprSyntax) -> String? {
            guard let member = expression.as(MemberAccessExprSyntax.self), let base = member.base,
                  Operand.containsOptionalChainingInClosure(base),
                  let name = renderer.bind(text(base), named: HoistedName.base(for: base) + "Result", from: Syntax(base))
            else { return nil }
            return name + "." + member.declName.trimmedDescription
        }

        // MARK: Rows

        func comparison(_ op: String, negatedTolerance: Bool) -> String? {
            guard arguments.positional.count >= 2 else { return nil }
            let operands = expected(0..<2)
            let lhs = operands[0]
            let rhs = operands[1]
            let prefix = Operand.prefix(lhs.effects, rhs.effects)
            let left = lhs.needsParentheses ? "(\(lhs.text))" : lhs.text
            let right = rhs.needsParentheses ? "(\(rhs.text))" : rhs.text

            if let accuracy = arguments.accuracy {
                let bound = Operand.needsParenthesesInComparison(accuracy) ? "(\(text(accuracy)))" : text(accuracy)
                let within = negatedTolerance ? ">" : "<="
                return "#expect(\(prefix)abs(\(left) - \(right)) \(within) \(bound)\(message(at: 2))\(location))"
            }
            if !lhs.isBound, lhs.core.is(ArrayExprSyntax.self), op == "==" || op == "!=" {
                // `XCTAssertEqual<T>` fixed `T` from both sides; `#expect` splits `==` into its
                // own overloads, where two untyped array literals are ambiguous. `elementsEqual`
                // makes the same claim (same count, same elements, in order) with one meaning.
                let negation = op == "!=" ? "!" : ""
                return "#expect(\(prefix)\(negation)\(lhs.text).elementsEqual(\(rhs.text))\(message(at: 2))\(location))"
            }
            return "#expect(\(prefix)\(left) \(op) \(right)\(message(at: 2))\(location))"
        }

        func truth(negated: Bool) -> String? {
            guard !arguments.positional.isEmpty else { return nil }
            let value = expected(0..<1, isWholeCondition: true)[0]
            let prefix = Operand.prefix(value.effects)
            let stated: String
            if negated {
                stated = value.isPostfixable ? "!" + value.text : "!(\(value.text))"
            } else {
                stated = value.text
            }
            return "#expect(\(prefix)\(stated)\(message(at: 1))\(location))"
        }

        func isNil() -> String? {
            guard !arguments.positional.isEmpty else { return nil }
            let value = expected(0..<1)[0]
            let subject = value.needsParentheses ? "(\(value.text))" : value.text
            return "#expect(\(Operand.prefix(value.effects))\(subject) == nil\(message(at: 1))\(location))"
        }

        /// `XCTAssertNotNil(x)` → `_ = try #require(x)`.
        ///
        /// `#expect(x != nil)` says the same thing and is what this gate's `weak-assertion`
        /// reports, so a conversion that wrote it would hand back a file the gate rejects.
        /// `#require` stops the test where XCTest carried on, which only matters to a test
        /// that went on to use a value it had just found missing.
        func required() -> String? {
            guard !arguments.positional.isEmpty else { return nil }
            _ = renderer.requireThrows(for: "XCTAssertNotNil", at: Syntax(call))
            let value = renderer.withinMacro(requiring: true) {
                bindingMutations([operand(arguments.positional[0], isWholeCondition: true)])[0]
            }
            // `#require` expands its argument into a closure an outer `try` or `await` does not
            // reach, so the operand keeps its own.
            return "_ = try #require(\(Operand.prefix(value.effects))\(value.text)\(message(at: 1))\(location))"
        }

        /// `XCTUnwrap(f())` → `#require(try f())` when this file declares `f` as throwing.
        ///
        /// `try XCTUnwrap(…)` covered a throwing call inside its autoclosure. `#require`
        /// expands its argument into a closure the outer `try` does not reach, so the call
        /// needs its own. That can only be known for functions this file declares. A
        /// throwing call from elsewhere is a compile error with the fix in its message.
        ///
        /// Inside another assertion the unwrap is bound on the line before instead.
        /// `#require` inside `#require` is "recursive expansion of macro", and the layout
        /// tests of BusinessMathExcel wrote exactly that:
        /// `XCTUnwrap(assignment.mapping[XCTUnwrap(model.node(named: "A"))])`.
        func unwrap() -> String? {
            guard let first = arguments.positional.first else { return nil }
            let isNested = renderer.macroDepth > 0
            let isNestedInRequire = renderer.requireDepth > 0

            let value = renderer.withinMacro(requiring: true) { () -> String in
                if let bound = boundClosureResult(first) { return bound }
                if !first.is(TryExprSyntax.self),
                   let call = first.as(FunctionCallExprSyntax.self),
                   let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
                   renderer.throwingFunctions.contains(callee.baseName.text) {
                    return "try " + text(first)
                }
                return text(first)
            }
            let macro = "#require(\(value)\(message(at: 1))\(location))"
            guard isNested else { return macro }

            if Operand.isCoveredByPlainTry(Syntax(call)),
               let name = renderer.bind("try " + macro, named: HoistedName.base(for: first), from: Syntax(call)) {
                return name
            }
            if isNestedInRequire {
                renderer.decline("XCTUnwrap inside XCTUnwrap: #require cannot contain another #require (\"recursive expansion of macro\"), and the inner unwrap cannot be bound ahead of this statement, because it sits in a closure or in a position that is not always evaluated. Unwrap the inner value in its own statement first.", at: Syntax(call))
            }
            return macro
        }

        func fail() -> String {
            guard let first = arguments.positional.first else { return "Issue.record(\(location.dropFirst(2)))" }
            return "Issue.record(\(MessageText.comment(first, text: text(first)))\(location))"
        }

        func noThrow() -> String? {
            guard let first = arguments.positional.first else { return nil }
            let body = renderer.throwingScope { text(first) }
            let awaited = ContainsAwait.found(in: Syntax(first)) ? "await " : ""
            return "\(awaited)#expect(throws: Never.self\(message(at: 1))\(location)) { \(body) }"
        }

        /// `XCTAssertThrowsError(e) { error in … }` → `if let error = #expect(throws:, performing:) { … }`.
        ///
        /// A closure that inspects `$0` is given a name, and only `$0` at the closure's own
        /// level is respelled. A nested closure's `$0` is a different value.
        ///
        /// The handler is found wherever it was written. It used to be looked for only after
        /// the call, so a handler passed as the last argument was dropped and its assertions
        /// with it, leaving the bare `throws: (any Error).self` of a test that inspected nothing.
        func throwsError() -> String? {
            guard let first = arguments.positional.first else { return nil }
            let handler = AssertionMapping.errorHandler(of: call)
            let handlerIsArgument = handler != nil && call.trailingClosure == nil
            let hasMessage = arguments.positional.count >= (handlerIsArgument ? 3 : 2)

            let body = renderer.throwingScope { text(first) }
            let awaited = ContainsAwait.found(in: Syntax(first)) ? "await " : ""
            let head = "#expect(throws: (any Error).self\(hasMessage ? message(at: 1) : "")\(location)"
            guard let handler else { return "\(awaited)\(head)) { \(body) }" }

            let performing = "\(awaited)\(head), performing: { \(body) })"
            guard let closure = handler.as(ClosureExprSyntax.self) else {
                return "if let error = \(performing) { \(text(handler))(error) }"
            }
            if LeavesHandler.found(in: closure), !Operand.isLastStatementOfVoidFunction(call) {
                renderer.decline("XCTAssertThrowsError: its closure contains `return`, which left the closure. Its statements become the body of an `if`, where `return` would leave the test and skip everything after this assertion. Restructure the closure so it does not return early.", at: Syntax(call))
            }
            let name = AssertionMapping.parameterName(of: closure) ?? "error"
            let statements = renderer.renderStatements(
                of: closure, dollarZeroAs: AssertionMapping.parameterName(of: closure) == nil ? name : nil)
            let closing = closure.rightBrace.leadingTrivia.description + "}"
            if name == "_" {
                return "if \(performing) != nil {\(statements)\(closing)"
            }
            return "if let \(name) = \(performing) {\(statements)\(closing)"
        }
    }
}

/// Finds a `return` at a closure's own level.
private final class LeavesHandler: SyntaxVisitor {
    private var result = false
    private var root: SyntaxIdentifier?

    static func found(in closure: ClosureExprSyntax) -> Bool {
        let visitor = LeavesHandler(viewMode: .sourceAccurate)
        visitor.root = closure.id
        visitor.walk(closure)
        return visitor.result
    }

    override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
        result = true
        return .skipChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        node.id == root ? .visitChildren : .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}
