import Foundation
import QualityGateCore
import SwiftSyntax

/// Walks a Swift syntax tree for the `fallback` rules.
///
/// One rule so far. **`fallback.int-conversion-unguarded`**: `Int(x)` on a
/// floating-point `x` traps when `x` is NaN, infinite, or merely too large, and
/// takes the process down with it. The conversion is accepted when, before it,
/// the enclosing function has bounded the value's magnitude in the conditions of
/// a `guard` — which a NaN cannot pass — or has bounded it anywhere and also
/// tested `isFinite`. `Int(exactly:)` is always accepted: it returns `nil`
/// instead.
///
/// Types come from syntax, in one file, and are never guessed: a parameter, an
/// annotated or initialised local, a generic parameter constrained to a
/// floating-point protocol, or a member whose every declaration in the file
/// agrees. A name with no declaration in reach is skipped.
final class FallbackVisitor: SyntaxVisitor {
    let filePath: String
    let converter: SourceLocationConverter
    let declarations: FallbackDeclarations

    /// Accumulated diagnostics from the walk.
    private(set) var diagnostics: [Diagnostic] = []

    /// Integer conversions of a floating-point value seen, guarded or not.
    private(set) var conversionsExamined = 0

    /// One lexical scope's worth of what the visitor has learned.
    private struct Scope {
        /// Names declared here, and what they hold.
        var names: [String: FallbackTypeKind] = [:]
        /// Generic parameters constrained to floating-point by this declaration.
        var genericNames: Set<String> = []
        /// The checks this body makes. Nil for a scope that is not a body.
        var facts: FallbackGuardFacts?
    }

    /// The scope stack, innermost last. The first element is the file itself.
    private var scopes: [Scope] = [Scope()]

    /// A floating-point value that reaches a conversion.
    private struct Subject {
        /// What a check on it would be recorded under, or nil for a value with
        /// no name — the result of a call — which nothing could have checked.
        let key: String?
        /// How it is spelled at the site, for the message.
        let display: String
    }

    /// Functions that return what they are given, as far as NaN is concerned.
    ///
    /// Rounding a NaN gives a NaN; so does taking its absolute value. `min` and
    /// `max` are here because a bound *might* survive them and might not —
    /// `Swift.min(1, .nan)` is `1`, `Swift.min(.nan, 1)` is `nan` — and "might"
    /// is not a guard.
    private static let passthroughFunctions: Set<String> = [
        "floor", "ceil", "round", "trunc", "rint", "abs", "fabs",
        "sqrt", "log", "log2", "log10", "exp", "pow", "min", "max"
    ]

    /// The same, for methods and properties on the value itself.
    private static let passthroughMembers: Set<String> = [
        "rounded", "squareRoot", "magnitude", "truncatingRemainder", "remainder"
    ]

    /// Operators whose result is a `Bool`, whatever their operands were.
    private static let booleanOperators: Set<String> = [
        "<", "<=", ">", ">=", "==", "!=", "&&", "||", "~="
    ]

    /// Creates a visitor.
    /// - Parameters:
    ///   - filePath: Path used in diagnostic output.
    ///   - converter: Source location converter for line and column lookup.
    ///   - declarations: What the file declares about its members and functions.
    init(
        filePath: String,
        converter: SourceLocationConverter,
        declarations: FallbackDeclarations
    ) {
        self.filePath = filePath
        self.converter = converter
        self.declarations = declarations
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Scope stack

    /// Every floating-point generic parameter in scope.
    private var genericNames: Set<String> {
        scopes.reduce(into: Set<String>()) { $0.formUnion($1.genericNames) }
    }

    private func pushScope(genericNames: Set<String> = [], body: Syntax? = nil) {
        var scope = Scope()
        scope.genericNames = genericNames
        if let body {
            scope.facts = FallbackGuardFactCollector.collect(
                from: body,
                genericNames: self.genericNames.union(genericNames)
            )
        }
        scopes.append(scope)
    }

    /// Leaves the innermost scope. The file scope is never popped.
    private func popScope() {
        guard scopes.count > 1 else { return }
        scopes.removeLast()
    }

    private func bind(_ name: String, kind: FallbackTypeKind) {
        scopes[scopes.count - 1].names[name] = kind
    }

    /// Looks a name up from the innermost scope outward, so an inner
    /// declaration shadows an outer one.
    private func kind(ofName name: String) -> FallbackTypeKind? {
        for scope in scopes.reversed() {
            if let kind = scope.names[name] { return kind }
        }
        return nil
    }

    private func kind(ofTypeText text: String) -> FallbackTypeKind {
        FallbackTypes.kind(ofTypeText: text, genericNames: genericNames)
    }

    // MARK: - Types

    /// Enters a type body, binding its annotated members before anything in it
    /// is read — a method may sit above the property it uses.
    private func enterType(genericNames: Set<String>, members: MemberBlockSyntax) {
        pushScope(genericNames: genericNames)
        for member in members.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      let annotation = binding.typeAnnotation else {
                    continue
                }
                let constant = FallbackTypes.isLiteralConstant(binding, in: variable)
                bind(
                    pattern.identifier.text,
                    kind: constant ? .other : kind(ofTypeText: annotation.type.trimmedDescription)
                )
            }
        }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(
            genericNames: FallbackTypes.genericFloatingPointNames(
                parameters: node.genericParameterClause, whereClause: node.genericWhereClause),
            members: node.memberBlock
        )
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) { popScope() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(
            genericNames: FallbackTypes.genericFloatingPointNames(
                parameters: node.genericParameterClause, whereClause: node.genericWhereClause),
            members: node.memberBlock
        )
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) { popScope() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(
            genericNames: FallbackTypes.genericFloatingPointNames(
                parameters: node.genericParameterClause, whereClause: node.genericWhereClause),
            members: node.memberBlock
        )
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) { popScope() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(
            genericNames: FallbackTypes.genericFloatingPointNames(
                parameters: node.genericParameterClause, whereClause: node.genericWhereClause),
            members: node.memberBlock
        )
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) { popScope() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let own = FallbackTypes.genericFloatingPointNames(parameters: nil, whereClause: node.genericWhereClause)
        let inherited = declarations.typeGenerics[node.extendedType.trimmedDescription] ?? []
        enterType(genericNames: own.union(inherited), members: node.memberBlock)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) { popScope() }

    // MARK: - Bodies

    private func bind(parameters: FunctionParameterListSyntax) {
        for parameter in parameters {
            let name = (parameter.secondName ?? parameter.firstName).text
            guard name != "_" else { continue }
            bind(name, kind: kind(ofTypeText: parameter.type.trimmedDescription))
        }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushScope(
            genericNames: FallbackTypes.genericFloatingPointNames(
                parameters: node.genericParameterClause, whereClause: node.genericWhereClause),
            body: node.body.map(Syntax.init)
        )
        bind(parameters: node.signature.parameterClause.parameters)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) { popScope() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushScope(
            genericNames: FallbackTypes.genericFloatingPointNames(
                parameters: node.genericParameterClause, whereClause: node.genericWhereClause),
            body: node.body.map(Syntax.init)
        )
        bind(parameters: node.signature.parameterClause.parameters)
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) { popScope() }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushScope(body: node.body.map(Syntax.init))
        return .visitChildren
    }

    override func visitPost(_ node: AccessorDeclSyntax) { popScope() }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let accessorBlock = node.accessorBlock {
            pushScope(body: Syntax(accessorBlock))
        }
        return .visitChildren
    }

    override func visitPost(_ node: PatternBindingSyntax) {
        if node.accessorBlock != nil {
            popScope()
        }
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        pushScope(body: Syntax(node.statements))
        guard let parameterClause = node.signature?.parameterClause else { return .visitChildren }

        switch parameterClause {
        case .simpleInput(let names):
            // Untyped, so unknown — but declared, so they shadow.
            for name in names {
                bind(name.name.text, kind: .other)
            }
        case .parameterClause(let clause):
            for parameter in clause.parameters {
                let name = (parameter.secondName ?? parameter.firstName).text
                guard name != "_" else { continue }
                bind(name, kind: parameter.type.map { kind(ofTypeText: $0.trimmedDescription) } ?? .other)
            }
        }
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) { popScope() }

    // MARK: - Bindings

    // Bound on the way *out*, so that in `let x = Int(x)` the inner `x` is still
    // the one the initialiser can see.
    override func visitPost(_ node: VariableDeclSyntax) {
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = pattern.identifier.text

            if FallbackTypes.isLiteralConstant(binding, in: node) {
                bind(name, kind: .other)
            } else if let annotation = binding.typeAnnotation {
                bind(name, kind: kind(ofTypeText: annotation.type.trimmedDescription))
            } else if let initializer = binding.initializer {
                bind(name, kind: kind(ofValue: initializer.value))
            } else {
                bind(name, kind: .other)
            }
        }
    }

    override func visitPost(_ node: OptionalBindingConditionSyntax) {
        // `if let x` with no initialiser re-binds the same value; the outer
        // declaration still describes it.
        guard let pattern = node.pattern.as(IdentifierPatternSyntax.self),
              let initializer = node.initializer else {
            return
        }
        if let annotation = node.typeAnnotation {
            bind(pattern.identifier.text, kind: kind(ofTypeText: annotation.type.trimmedDescription))
        } else {
            bind(pattern.identifier.text, kind: kind(ofValue: initializer.value))
        }
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        guard let pattern = node.pattern.as(IdentifierPatternSyntax.self) else { return .visitChildren }

        var element = FallbackTypeKind.other
        if let annotation = node.typeAnnotation {
            element = kind(ofTypeText: annotation.type.trimmedDescription)
        } else if let sequence = node.sequence.as(DeclReferenceExprSyntax.self),
                  kind(ofName: sequence.baseName.text) == .floatingPointCollection {
            element = .floatingPoint
        }
        bind(pattern.identifier.text, kind: element)
        return .visitChildren
    }

    /// The kind of a value bound without an annotation.
    private func kind(ofValue value: ExprSyntax) -> FallbackTypeKind {
        if value.is(FloatLiteralExprSyntax.self) {
            return .floatingPoint
        }
        if let array = value.as(ArrayExprSyntax.self), !array.elements.isEmpty,
           array.elements.allSatisfy({ $0.expression.is(FloatLiteralExprSyntax.self) }) {
            return .floatingPointCollection
        }
        if let reference = value.as(DeclReferenceExprSyntax.self),
           let known = kind(ofName: reference.baseName.text) {
            return known
        }
        return subjects(of: value).isEmpty ? .other : .floatingPoint
    }

    // MARK: - The conversion

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
              FallbackTypes.integerTypeNames.contains(callee.baseName.text),
              kind(ofName: callee.baseName.text) == nil,
              node.arguments.count == 1,
              let argument = node.arguments.first,
              argument.label == nil else {
            return .visitChildren
        }

        let converted = subjects(of: argument.expression)
        guard !converted.isEmpty else { return .visitChildren }
        conversionsExamined += 1

        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let unguarded = converted.compactMap { subject -> Finding? in
            let written = checks(on: subject, before: offset)
            let asserted = checks(on: subject, before: offset, assertedOnly: true)
            let representable = Self.isBounded(asserted)
                || (written.contains(.finite) && Self.isBounded(written))
            return representable ? nil : Finding(subject: subject, checks: written)
        }
        guard let first = unguarded.first else { return .visitChildren }

        emit(
            typeName: callee.baseName.text,
            finding: first,
            node: Syntax(node)
        )
        return .visitChildren
    }

    /// A subject that reached a conversion without the checks it needs.
    private struct Finding {
        let subject: Subject
        let checks: Set<FallbackGuardFacts.Kind>
    }

    /// The checks made on a subject, or on anything that is the same value,
    /// before `offset`, in any enclosing body.
    private func checks(
        on subject: Subject,
        before offset: Int,
        assertedOnly: Bool = false
    ) -> Set<FallbackGuardFacts.Kind> {
        guard let key = subject.key else { return [] }

        var keys: Set<String> = [key]
        for scope in scopes {
            guard let facts = scope.facts else { continue }
            keys.formUnion(facts.equivalents(of: key))
        }

        var found: Set<FallbackGuardFacts.Kind> = []
        for scope in scopes {
            guard let facts = scope.facts else { continue }
            found.formUnion(facts.kinds(for: keys, before: offset, assertedOnly: assertedOnly))
        }
        return found
    }

    /// Bounded in magnitude, or from both sides.
    private static func isBounded(_ checks: Set<FallbackGuardFacts.Kind>) -> Bool {
        checks.contains(.magnitudeBound)
            || (checks.contains(.lowerBound) && checks.contains(.upperBound))
    }

    // MARK: - Floating-point subjects

    /// The named floating-point values an expression is computed from.
    ///
    /// Empty means "nothing here is known to be floating-point", which covers
    /// literals, integers converted upward (`Double(count) * 0.95`) and names
    /// with no declaration in reach. None of those is a finding.
    ///
    /// - Parameters:
    ///   - expr: The expression to read.
    ///   - depth: Recursion budget. Guarded so the walk terminates on any input.
    private func subjects(of expr: ExprSyntax, depth: Int = 0) -> [Subject] {
        guard depth < 12 else { return [] }
        let next = depth + 1

        if let reference = expr.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            return kind(ofName: name) == .floatingPoint ? [Subject(key: name, display: name)] : []
        }

        if let member = expr.as(MemberAccessExprSyntax.self) {
            return subjects(ofMember: member, depth: next)
        }

        if let call = expr.as(FunctionCallExprSyntax.self) {
            return subjects(ofCall: call, depth: next)
        }

        if let sequence = expr.as(SequenceExprSyntax.self) {
            return subjects(ofSequence: Array(sequence.elements), depth: next)
        }

        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            if let op = infix.operator.as(BinaryOperatorExprSyntax.self),
               Self.booleanOperators.contains(op.operator.text) {
                return []
            }
            return subjects(of: infix.leftOperand, depth: next) + subjects(of: infix.rightOperand, depth: next)
        }

        if let ternary = expr.as(TernaryExprSyntax.self) {
            return subjects(of: ternary.thenExpression, depth: next)
                + subjects(of: ternary.elseExpression, depth: next)
        }

        guard let inner = wrapped(in: expr) else { return [] }
        return subjects(of: inner, depth: next)
    }

    /// The expression inside `try`, `await`, `( )`, `?`, `!` or a prefix
    /// operator — wrappers that change nothing about what the value is.
    private func wrapped(in expr: ExprSyntax) -> ExprSyntax? {
        if let tryExpr = expr.as(TryExprSyntax.self) { return tryExpr.expression }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) { return awaitExpr.expression }
        if let chained = expr.as(OptionalChainingExprSyntax.self) { return chained.expression }
        if let unwrapped = expr.as(ForceUnwrapExprSyntax.self) { return unwrapped.expression }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            return prefix.operator.text == "!" ? nil : prefix.expression
        }
        if let tuple = expr.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first,
           only.label == nil {
            return only.expression
        }
        return nil
    }

    private func subjects(ofMember member: MemberAccessExprSyntax, depth: Int) -> [Subject] {
        let name = member.declName.baseName.text
        guard let base = member.base else { return [] }

        // `self.periods` and `Self.deadline` are `periods` and `deadline`.
        if let reference = base.as(DeclReferenceExprSyntax.self),
           reference.baseName.text == "self" || reference.baseName.text == "Self" {
            return kind(ofName: name) == .floatingPoint ? [Subject(key: name, display: name)] : []
        }

        // `Double.pi`, `T.zero`: a constant of the type, not a value that arrived.
        if let reference = base.as(DeclReferenceExprSyntax.self),
           FallbackTypes.floatingPointTypeNames.contains(reference.baseName.text)
            || genericNames.contains(reference.baseName.text) {
            return []
        }

        if Self.passthroughMembers.contains(name) {
            return subjects(of: base, depth: depth)
        }

        guard declarations.memberKinds[name] == .floatingPoint else { return [] }
        let text = member.trimmedDescription
        return [Subject(key: FallbackSubjectKey.normalised(text), display: text)]
    }

    private func subjects(ofCall call: FunctionCallExprSyntax, depth: Int) -> [Subject] {
        let arguments = call.arguments.flatMap { subjects(of: $0.expression, depth: depth) }

        if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = callee.baseName.text

            // `Double(x)` is `x`; `floor(x)` is as finite as `x` was.
            if FallbackTypes.floatingPointTypeNames.contains(name)
                || genericNames.contains(name)
                || Self.passthroughFunctions.contains(name) {
                return arguments
            }

            // A function this file declares as returning floating-point. Its
            // result has no name, so nothing can have checked it.
            if declarations.returnKinds[name] == .floatingPoint, kind(ofName: name) == nil {
                return [Subject(key: nil, display: call.trimmedDescription)]
            }
            return []
        }

        if let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
           let base = callee.base,
           Self.passthroughMembers.contains(callee.declName.baseName.text) {
            return subjects(of: base, depth: depth) + arguments
        }
        return []
    }

    private func subjects(ofSequence elements: [ExprSyntax], depth: Int) -> [Subject] {
        // A comparison or a logical operator makes the whole thing a `Bool`.
        let isBoolean = elements.contains { element in
            guard let op = element.as(BinaryOperatorExprSyntax.self) else { return false }
            return Self.booleanOperators.contains(op.operator.text)
        }

        // `condition ? a : b` — the condition chooses a value, it is not one.
        if let ternaryIndex = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }) {
            var values = Array(elements[elements.index(after: ternaryIndex)...])
            if let ternary = elements[ternaryIndex].as(UnresolvedTernaryExprSyntax.self) {
                values.append(ternary.thenExpression)
            }
            return values.flatMap { subjects(of: $0, depth: depth) }
        }

        guard !isBoolean else { return [] }
        return elements
            .filter { !$0.is(BinaryOperatorExprSyntax.self) }
            .flatMap { subjects(of: $0, depth: depth) }
    }

    // MARK: - Emission

    private func emit(typeName: String, finding: Finding, node: Syntax) {
        let location = node.startLocation(converter: converter)
        let name = finding.subject.display
        let trap = "\(typeName)(.nan), \(typeName)(.infinity) and \(typeName)(1e300) all stop the process"

        let message: String
        if finding.subject.key == nil {
            message = """
            '\(typeName)(\(name))' converts a floating-point result that has no name, so nothing \
            can have checked it. \(trap). Bind it to a local and check that, or use \
            \(typeName)(exactly:).
            """
        } else if finding.checks.contains(.finite) {
            message = """
            '\(name)' is checked with isFinite, and that is not enough: 1e300 is finite and \
            \(typeName)(1e300) still traps. \(trap). The conversion needs a bound on the \
            magnitude as well.
            """
        } else if Self.isBounded(finding.checks) {
            message = """
            '\(name)' is compared against a range, but nothing asserts the result: the \
            comparison is not a condition of a guard, and there is no isFinite. Every comparison \
            with a NaN is false, so a range test that is negated or stored lets one through. \(trap).
            """
        } else {
            message = """
            '\(name)' is floating-point and nothing before this conversion shows it is \
            representable. \(trap).
            """
        }

        diagnostics.append(
            Diagnostic(
                severity: .error,
                message: message,
                filePath: filePath,
                lineNumber: location.line,
                columnNumber: location.column,
                ruleId: FallbackRuleID.intConversionUnguarded,
                suggestedFix: """
                Either guard first — 'guard x.isFinite, abs(x) < limit else { … }' — or convert with \
                '\(typeName)(exactly: x.rounded(.towardZero))', which returns nil instead of trapping. \
                \(typeName)(exactly:) alone is nil for any value with a fractional part.
                """
            )
        )
    }
}
