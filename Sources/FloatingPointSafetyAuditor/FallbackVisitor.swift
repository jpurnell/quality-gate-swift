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
    var diagnostics: [Diagnostic] = []

    /// Nested `min` / `max` clamps of a floating-point value seen.
    var clampsExamined = 0

    /// `if` / `else if` chains that sort one floating-point value seen.
    var classificationsExamined = 0

    /// Guards that a NaN fails and that answer with a value seen, documented
    /// or not.
    var guardsExamined = 0

    /// Findings a justification silenced. Recorded rather than dropped, so that
    /// the justifications can be read as a list.
    var overrides: [DiagnosticOverride] = []

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
        /// What documents the value this scope returns.
        var documentation = FallbackDocumentation.inherited
    }

    /// The scope stack, innermost last. The first element is the file itself.
    private var scopes: [Scope] = [Scope()]

    /// A floating-point value that reaches a conversion, a clamp or a comparison.
    struct Subject {
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
    static let passthroughFunctions: Set<String> = [
        "floor", "ceil", "round", "trunc", "rint", "abs", "fabs",
        "sqrt", "log", "log2", "log10", "exp", "pow", "min", "max"
    ]

    /// The same, for methods and properties on the value itself.
    static let passthroughMembers: Set<String> = [
        "rounded", "squareRoot", "magnitude", "truncatingRemainder", "remainder"
    ]

    /// Operators whose result is a `Bool`, whatever their operands were.
    static let booleanOperators: Set<String> = [
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
    var genericNames: Set<String> {
        scopes.reduce(into: Set<String>()) { $0.formUnion($1.genericNames) }
    }

    private func pushScope(
        genericNames: Set<String> = [],
        body: Syntax? = nil,
        documentation: FallbackDocumentation = .inherited
    ) {
        var scope = Scope()
        scope.genericNames = genericNames
        scope.documentation = documentation
        if let body {
            scope.facts = FallbackGuardFactCollector.collect(
                from: body,
                genericNames: self.genericNames.union(genericNames)
            )
        }
        scopes.append(scope)
    }

    /// The text documenting what a `return` here returns, or nil if nothing does.
    ///
    /// Read from the innermost scope that returns on its own behalf: a closure's
    /// `return` is the closure's, and the enclosing function's documentation
    /// does not describe it.
    func returnDocumentation() -> String? {
        for scope in scopes.reversed() {
            switch scope.documentation {
            case .inherited: continue
            case .undocumented: return nil
            case .text(let text): return text
            }
        }
        return nil
    }

    /// Seeds the file scope with the checks top-level code makes.
    ///
    /// Without this a script that bounds a value and then converts it was
    /// reported as though it had not: every enclosing body's facts were read
    /// except the outermost one, which had none.
    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind {
        scopes[0].facts = FallbackGuardFactCollector.collectTopLevel(from: node, genericNames: genericNames)
        return .visitChildren
    }

    /// Leaves the innermost scope. The file scope is never popped.
    private func popScope() {
        guard scopes.count > 1 else { return }
        scopes.removeLast()
    }

    func bind(_ name: String, kind: FallbackTypeKind) {
        scopes[scopes.count - 1].names[name] = kind
    }

    /// Looks a name up from the innermost scope outward, so an inner
    /// declaration shadows an outer one.
    func kind(ofName name: String) -> FallbackTypeKind? {
        for scope in scopes.reversed() {
            if let kind = scope.names[name] { return kind }
        }
        return nil
    }

    func kind(ofTypeText text: String) -> FallbackTypeKind {
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
                let declared = kind(ofTypeText: annotation.type.trimmedDescription)
                let constant = FallbackTypes.isLiteralConstant(binding, in: variable)
                bind(
                    pattern.identifier.text,
                    kind: constant && declared == .floatingPoint ? .finiteFloatingPoint : declared
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
        for parameter in FallbackTypes.parameters(of: parameters) {
            bind(parameter.name, kind: parameter.typeText.map(kind(ofTypeText:)) ?? .other)
        }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushScope(
            genericNames: FallbackTypes.genericFloatingPointNames(
                parameters: node.genericParameterClause, whereClause: node.genericWhereClause),
            body: node.body.map(Syntax.init),
            documentation: Self.returnsClause(in: node.leadingTrivia).map { .text($0) } ?? .undocumented
        )
        bind(parameters: node.signature.parameterClause.parameters)
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) { popScope() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        pushScope(
            genericNames: FallbackTypes.genericFloatingPointNames(
                parameters: node.genericParameterClause, whereClause: node.genericWhereClause),
            body: node.body.map(Syntax.init),
            documentation: .undocumented
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
            // A property has no Returns clause. Its whole comment is about what
            // it returns.
            let declaration = node.parent?.parent?.as(VariableDeclSyntax.self)
            let lines = declaration.map { Self.documentationLines(in: $0.leadingTrivia) } ?? []
            pushScope(
                body: Syntax(accessorBlock),
                documentation: lines.isEmpty ? .undocumented : .text(lines.joined(separator: " "))
            )
        }
        return .visitChildren
    }

    override func visitPost(_ node: PatternBindingSyntax) {
        if node.accessorBlock != nil {
            popScope()
        }
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        pushScope(body: Syntax(node.statements), documentation: .undocumented)
        // Typed parameters are what they are declared to be. Untyped ones are
        // unknown — but declared, so they shadow.
        for parameter in FallbackTypes.parameters(of: node.signature) {
            bind(parameter.name, kind: parameter.typeText.map(kind(ofTypeText:)) ?? .other)
        }
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) { popScope() }

    // MARK: - Bindings

    // Bound on the way *out*, so that in `let x = Int(x)` the inner `x` is still
    // the one the initialiser can see.
    override func visitPost(_ node: VariableDeclSyntax) {
        let isLet = node.bindingSpecifier.tokenKind == .keyword(.let)
        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let bound = kind(of: binding, isLet: isLet)
            // `let deadline: TimeInterval = 30` is declared floating-point and
            // initialised from an integer literal, which evaluates to nothing.
            let constant = FallbackTypes.isLiteralConstant(binding, in: node) && bound == .floatingPoint
            bind(pattern.identifier.text, kind: constant ? .finiteFloatingPoint : bound)
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
            bind(pattern.identifier.text, kind: kind(ofValue: initializer.value, isLet: false))
        }
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        // `for value in values`
        if let pattern = node.pattern.as(IdentifierPatternSyntax.self) {
            var element = FallbackTypeKind.other
            if let annotation = node.typeAnnotation {
                element = kind(ofTypeText: annotation.type.trimmedDescription)
            } else if isFloatingPointCollection(node.sequence) {
                element = .floatingPoint
            }
            bind(pattern.identifier.text, kind: element)
            return .visitChildren
        }

        // `for (index, value) in values.enumerated()`
        guard let tuple = node.pattern.as(TuplePatternSyntax.self) else { return .visitChildren }
        let names = tuple.elements.map { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
        var kinds = [FallbackTypeKind](repeating: .other, count: names.count)
        if names.count == 2,
           let call = node.sequence.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
           callee.declName.baseName.text == "enumerated",
           let base = callee.base,
           isFloatingPointCollection(base) {
            kinds[1] = .floatingPoint
        }
        for (name, kind) in zip(names, kinds) {
            guard let name, name != "_" else { continue }
            bind(name, kind: kind)
        }
        return .visitChildren
    }

    /// The kind a declaration gives its name.
    ///
    /// A `let` is what it was computed from. A `var` is only what it is declared
    /// to be, because it will be something else by the time it is read.
    private func kind(of binding: PatternBindingSyntax, isLet: Bool) -> FallbackTypeKind {
        let value = binding.initializer?.value

        if let annotation = binding.typeAnnotation {
            let declared = kind(ofTypeText: annotation.type.trimmedDescription)
            guard declared == .floatingPoint, isLet, let value,
                  case .finite = evaluate(value) else {
                return declared
            }
            return .finiteFloatingPoint
        }
        guard let value else { return .other }
        return kind(ofValue: value, isLet: isLet)
    }

    /// The kind of a value bound without an annotation.
    private func kind(ofValue value: ExprSyntax, isLet: Bool) -> FallbackTypeKind {
        if let array = value.as(ArrayExprSyntax.self), !array.elements.isEmpty,
           array.elements.allSatisfy({ $0.expression.is(FloatLiteralExprSyntax.self) }) {
            return .floatingPointCollection
        }
        if let reference = value.as(DeclReferenceExprSyntax.self),
           kind(ofName: reference.baseName.text) == .floatingPointCollection {
            return .floatingPointCollection
        }
        switch evaluate(value) {
        case .carriesNaN:
            return .floatingPoint
        case .finite:
            return isLet ? .finiteFloatingPoint : .floatingPoint
        case .unknown, .literal:
            return .other
        }
    }

    // MARK: - The conversion

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        checkClamp(node)
        checkConversion(node)
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        checkClassification(node)
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        checkGuard(node)
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        learnFromComparisons(in: node)
        return .visitChildren
    }

    private func checkConversion(_ node: FunctionCallExprSyntax) {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
              FallbackTypes.integerTypeNames.contains(callee.baseName.text),
              kind(ofName: callee.baseName.text) == nil,
              node.arguments.count == 1,
              let argument = node.arguments.first,
              argument.label == nil else {
            return
        }

        let converted = subjects(of: argument.expression)
        guard !converted.isEmpty else { return }
        conversionsExamined += 1

        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let unguarded = converted.compactMap { subject -> Finding? in
            let written = checks(on: subject, before: offset)
            let asserted = checks(on: subject, before: offset, assertedOnly: true)
            let representable = Self.isBounded(asserted)
                || (written.contains(.finite) && Self.isBounded(written))
            return representable ? nil : Finding(subject: subject, checks: written)
        }
        guard let first = unguarded.first else { return }

        emit(
            typeName: callee.baseName.text,
            finding: first,
            node: Syntax(node)
        )
    }

    /// A subject that reached a conversion without the checks it needs.
    private struct Finding {
        let subject: Subject
        let checks: Set<FallbackGuardFacts.Kind>
    }

    /// The checks made on a subject, or on anything that is the same value,
    /// before `offset`, in any enclosing body.
    func checks(
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
