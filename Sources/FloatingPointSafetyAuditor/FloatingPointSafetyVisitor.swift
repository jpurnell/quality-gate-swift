import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Constants

/// Known floating-point type names used for heuristic type detection.
private let fpTypeNames: Set<String> = [
    "Double", "Float", "CGFloat", "Float16", "Float80", "Decimal"
]

/// Generic collection types whose `==` compares elementwise.
private let fpCollectionTypeNames: Set<String> = [
    "Array", "ArraySlice", "ContiguousArray"
]

/// The static members of a floating-point type that are themselves *of* that type.
///
/// This is an allowlist rather than a wildcard because the type of an arbitrary
/// static member cannot be known from syntax. `Double.dimension` is an `Int` —
/// it comes from a `VectorSpace` conformance, not from `Double`'s own storage —
/// and treating every member access on a `Double` base as floating-point flagged
/// it three times in BusinessMath. Anything not named here is unknown, and
/// unknown is not floating-point.
private let floatingPointStaticMembers: Set<String> = [
    "pi", "infinity", "nan", "signalingNaN", "ulpOfOne",
    "greatestFiniteMagnitude", "leastNormalMagnitude", "leastNonzeroMagnitude", "zero"
]

/// The bit-inspection members, exempt because `a.bitPattern == b.bitPattern` is
/// the unambiguous bit-identity form the diagnostic recommends. Flagging it
/// would punish the fix.
private let bitInspectionMemberNames: Set<String> = [
    "bitPattern", "significandBitPattern"
]

/// Member-access names that are exempt from the fp-equality rule.
///
/// Derived from ``floatingPointStaticMembers`` rather than listed separately:
/// the two lists overlapped on eight of nine names and disagreed on the ninth
/// (`signalingNaN` was an allowlisted member but not an exempt sentinel), which
/// is exactly how two hand-maintained copies of one idea drift. A static member
/// that *is* the floating-point type is by construction a sentinel — there is no
/// arithmetic behind `.pi` or `.greatestFiniteMagnitude` to have rounded — so
/// membership of one list implies membership of the other.
private let exemptMemberNames: Set<String> = floatingPointStaticMembers.union(bitInspectionMemberNames)

// MARK: - Operand shape

/// Whether a floating-point operand is a single value or a collection of them.
///
/// The distinction changes the advice, not just the wording: `==` on `[Double]`
/// compares elementwise, so `a.bitPattern == b.bitPattern` does not typecheck
/// and a caller who follows scalar advice writes something that cannot compile.
enum FloatingPointShape: Sendable {
    /// A single floating-point value.
    case scalar
    /// A collection of floating-point values, compared elementwise by `==`.
    case collection
}

/// How much the visitor had to infer to decide an operand is floating-point.
///
/// The two rules ask different questions of the same operand and deserve
/// different evidence bars. `fp-equality` asks which of three claims an `==` is
/// making, and is worth raising whenever the operand is plausibly floating-point.
/// `fp-division-unguarded` asks whether a divisor could be zero, and its answer
/// is a guard added to shipping code — so it stays on evidence written at the
/// site and does not follow inference chains.
enum FloatingPointEvidence: Sendable {
    /// Written down at the point of use or of declaration: a literal, a type
    /// annotation, a conversion call, an allowlisted static member.
    case direct
    /// Recovered by following a chain: a local bound from a conversion, or from
    /// a call to a function this file declares a return type for.
    case inferred
}

/// What the visitor concluded about one operand.
struct FloatingPointOperand: Sendable {
    /// Whether the operand is a single value or a collection of them.
    let shape: FloatingPointShape
    /// How much had to be inferred to reach that conclusion.
    let evidence: FloatingPointEvidence
}

// MARK: - Visitor

/// Walks a Swift syntax tree looking for floating-point safety issues.
///
/// Detects two classes of problems:
/// - **fp-equality**: Exact `==` / `!=` comparison where at least one operand
///   appears to be floating-point (heuristic, syntax-only).
/// - **fp-division-unguarded**: Division (`/` or `/=`) where the divisor appears
///   to be floating-point and no zero-guard is visible in the enclosing scope.
///
/// Because SwiftSyntax provides syntax, not types, the visitor uses conservative
/// heuristics: float literals (`FloatLiteralExprSyntax`), explicit type
/// annotations (`let x: Double`), and member-access on known FP type names.
final class FloatingPointSafetyVisitor: SyntaxVisitor {
    let filePath: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let checkDivisionGuards: Bool

    /// Whether files under a `Tests/` path are skipped entirely.
    ///
    /// `fp-safety` walks `Sources/` and skips test code; `test-quality` walks
    /// `Tests/` and must not. Same detector, different reach.
    let skipTestFiles: Bool

    /// Rule identifier for the exact-comparison finding. `fp-safety` reports it
    /// as `fp-equality`, `test-quality` as `exact-double-equality`.
    let equalityRuleId: String

    /// Severity for the exact-comparison finding.
    let equalitySeverity: Diagnostic.Severity

    /// When true, exact-comparison findings are emitted only inside `#expect`
    /// / `#require` arguments.
    let equalityRequiresAssertionContext: Bool

    /// Comment markers that suppress a finding on the line they appear on, or
    /// on the line below when the marker sits on a comment-only line.
    let suppressionMarkers: [String]

    /// Accumulated diagnostics from the walk.
    private(set) var diagnostics: [Diagnostic] = []

    /// Findings a suppression marker silenced. Recorded rather than dropped so
    /// suppressions stay auditable.
    private(set) var overrides: [DiagnosticOverride] = []

    /// Return types of functions declared in this file, by name, for names that
    /// resolve unambiguously. See ``FunctionReturnTypeCollector``.
    let fileLocalReturnTypes: [String: String]

    /// Nesting depth of enclosing `#expect` / `#require` macro expansions.
    private var assertionDepth = 0

    /// One lexical scope's worth of what the visitor has learned about names.
    ///
    /// Bindings are per-scope because they were once per-file, and a name
    /// binding that outlives the declaration that introduced it is simply wrong:
    /// a local `result` holding an `Int` was reported as floating-point because
    /// an unrelated test elsewhere in the same file declared `let result: Double`.
    private struct DeclarationScope {
        /// Names known to hold floating-point values, and on what evidence.
        var floatingPointNames: [String: FloatingPointOperand] = [:]

        /// Names whose enclosing body contains a visible zero-guard.
        var guardedVariables: Set<String> = []
    }

    /// The scope stack, innermost last. The first element is the file itself,
    /// which holds top-level and type-member bindings.
    private var scopes: [DeclarationScope] = [DeclarationScope()]

    /// Creates a new floating-point safety visitor.
    /// - Parameters:
    ///   - filePath: Absolute path used in diagnostic output.
    ///   - converter: Source location converter for line/column lookup.
    ///   - sourceLines: The source split by newline, for per-line disable checks.
    ///   - checkDivisionGuards: Whether to apply the `fp-division-unguarded` rule.
    ///   - skipTestFiles: Whether to skip files under a `Tests/` path.
    ///   - equalityRuleId: Rule identifier for the exact-comparison finding.
    ///   - equalitySeverity: Severity for the exact-comparison finding.
    ///   - equalityRequiresAssertionContext: Restrict exact-comparison findings
    ///     to `#expect` / `#require` arguments.
    ///   - suppressionMarkers: Comment markers that silence a finding.
    ///   - fileLocalReturnTypes: Unambiguous return types of functions declared
    ///     in this file, used to type locals bound from a call to one of them.
    init(
        filePath: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        checkDivisionGuards: Bool = true,
        skipTestFiles: Bool = true,
        equalityRuleId: String = "fp-equality",
        equalitySeverity: Diagnostic.Severity = .warning,
        equalityRequiresAssertionContext: Bool = false,
        suppressionMarkers: [String] = FloatingPointSuppression.allMarkers,
        fileLocalReturnTypes: [String: String] = [:]
    ) {
        self.filePath = filePath
        self.converter = converter
        self.sourceLines = sourceLines
        self.checkDivisionGuards = checkDivisionGuards
        self.skipTestFiles = skipTestFiles
        self.equalityRuleId = equalityRuleId
        self.equalitySeverity = equalitySeverity
        self.equalityRequiresAssertionContext = equalityRequiresAssertionContext
        self.suppressionMarkers = suppressionMarkers
        self.fileLocalReturnTypes = fileLocalReturnTypes
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Scope Stack

    /// Records `name` as holding a floating-point value in the innermost scope.
    private func bind(_ name: String, operand: FloatingPointOperand) {
        scopes[scopes.count - 1].floatingPointNames[name] = operand
    }

    /// Looks a name up from the innermost scope outward, so an inner binding
    /// shadows an outer one rather than colliding with it.
    private func operand(forName name: String) -> FloatingPointOperand? {
        for scope in scopes.reversed() {
            if let operand = scope.floatingPointNames[name] { return operand }
        }
        return nil
    }

    /// Returns true if any enclosing scope has a visible zero-guard on `name`.
    private func isGuarded(_ name: String) -> Bool {
        scopes.contains { $0.guardedVariables.contains(name) }
    }

    /// Enters a new lexical scope, optionally seeded with the zero-guards
    /// visible in `body`.
    private func pushScope(collectingGuardsFrom body: Syntax?) {
        var scope = DeclarationScope()
        if let body, checkDivisionGuards {
            var guards: Set<String> = []
            collectGuardedVariables(from: body, into: &guards)
            scope.guardedVariables = guards
        }
        scopes.append(scope)
    }

    /// Leaves the innermost scope. The file scope is never popped.
    private func popScope() {
        guard scopes.count > 1 else { return }
        scopes.removeLast()
    }

    // MARK: - Skip Test Files

    /// Returns true if this file should not be analysed at all.
    private var isTestFile: Bool {
        guard skipTestFiles else { return false }
        return filePath.contains("/Tests/") || filePath.hasPrefix("Tests/")
    }

    // MARK: - Assertion Context

    /// Returns true if the macro is a swift-testing assertion.
    private func isAssertionMacro(_ node: MacroExpansionExprSyntax) -> Bool {
        let name = node.macroName.text
        return name == "expect" || name == "require"
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        if isAssertionMacro(node) {
            assertionDepth += 1
        }
        return .visitChildren
    }

    override func visitPost(_ node: MacroExpansionExprSyntax) {
        if isAssertionMacro(node) {
            assertionDepth = max(0, assertionDepth - 1)
        }
    }

    // MARK: - Variable Declaration Tracking

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }
            let varName = pattern.identifier.text

            // An explicit annotation is the strongest signal: `let x: Double`,
            // `let xs: [Double]`.
            if let typeAnnotation = binding.typeAnnotation,
               let annotated = floatingPointShape(ofTypeText: typeAnnotation.type.trimmedDescription) {
                bind(varName, operand: FloatingPointOperand(shape: annotated, evidence: .direct))
                continue
            }

            // Otherwise read the initializer: a float literal or an array
            // literal of them is written down; a conversion or a call to a
            // function this file declares a return type for is a chain, and the
            // binding carries that provenance forward.
            if let initializer = binding.initializer,
               let source = floatingPointOperand(of: initializer.value) {
                let isLiteral = initializer.value.is(FloatLiteralExprSyntax.self)
                    || initializer.value.is(ArrayExprSyntax.self)
                let evidence: FloatingPointEvidence = isLiteral ? .direct : .inferred
                bind(varName, operand: FloatingPointOperand(shape: source.shape, evidence: evidence))
            }
        }
        return .visitChildren
    }

    // MARK: - Lexical Scopes

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: node.body.map(Syntax.init))
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        popScope()
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: node.body.map(Syntax.init))
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        popScope()
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: node.body.map(Syntax.init))
        return .visitChildren
    }

    override func visitPost(_ node: AccessorDeclSyntax) {
        popScope()
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: Syntax(node.statements))
        return .visitChildren
    }

    override func visitPost(_ node: ClosureExprSyntax) {
        popScope()
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        if let accessorBlock = node.accessorBlock {
            pushScope(collectingGuardsFrom: Syntax(accessorBlock))
        }
        return .visitChildren
    }

    override func visitPost(_ node: PatternBindingSyntax) {
        if node.accessorBlock != nil {
            popScope()
        }
    }

    // A type body is a scope too: two `@Suite` structs in one file each declare
    // their own `result`, and neither should be able to name the other's.

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: nil)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        popScope()
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: nil)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        popScope()
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: nil)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        popScope()
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: nil)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        popScope()
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        pushScope(collectingGuardsFrom: nil)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        popScope()
    }

    // MARK: - Sequence Expression Analysis

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }

        let elements = Array(node.elements)

        for (index, element) in elements.enumerated() {
            guard let binOp = element.as(BinaryOperatorExprSyntax.self) else {
                continue
            }
            let opText = binOp.operator.text

            if opText == "==" || opText == "!=" {
                checkEqualityOperator(elements: elements, operatorIndex: index, opText: opText, node: Syntax(node))
            } else if (opText == "/" || opText == "/=") && checkDivisionGuards {
                checkDivisionOperator(elements: elements, operatorIndex: index, opText: opText, node: Syntax(node))
            }
        }

        return .visitChildren
    }

    // MARK: - Infix Operator (post-fold fallback)

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }

        guard let binOp = node.operator.as(BinaryOperatorExprSyntax.self) else {
            return .visitChildren
        }
        let opText = binOp.operator.text

        if opText == "==" || opText == "!=" {
            checkInfixEquality(lhs: node.leftOperand, rhs: node.rightOperand, opText: opText, node: Syntax(node))
        } else if (opText == "/" || opText == "/=") && checkDivisionGuards {
            checkInfixDivision(divisor: node.rightOperand, node: Syntax(node))
        }

        return .visitChildren
    }

    // MARK: - Equality Checks (SequenceExpr)

    private func checkEqualityOperator(
        elements: [ExprSyntax],
        operatorIndex: Int,
        opText: String,
        node: Syntax
    ) {
        let lhsIndex = operatorIndex - 1
        let rhsIndex = operatorIndex + 1
        guard lhsIndex >= 0, rhsIndex < elements.count else { return }

        let lhs = elements[lhsIndex]
        let rhs = elements[rhsIndex]
        checkInfixEquality(lhs: lhs, rhs: rhs, opText: opText, node: node)
    }

    /// Emits the shared exact-comparison finding, honouring the assertion-context
    /// restriction the calling checker asked for.
    private func emitEqualityDiagnostic(opText: String, node: Syntax, elementwise: Bool) {
        if equalityRequiresAssertionContext && assertionDepth == 0 { return }

        emitDiagnostic(
            ruleId: equalityRuleId,
            severity: equalitySeverity,
            message: FloatingPointEqualityDiagnostic.message(operatorText: opText, elementwise: elementwise),
            node: node,
            suggestedFix: FloatingPointEqualityDiagnostic.suggestedFix(operatorText: opText, elementwise: elementwise)
        )
    }

    // MARK: - Equality Checks (InfixOperatorExpr)

    private func checkInfixEquality(
        lhs: ExprSyntax,
        rhs: ExprSyntax,
        opText: String,
        node: Syntax
    ) {
        let lhsOperand = floatingPointOperand(of: lhs)
        let rhsOperand = floatingPointOperand(of: rhs)

        guard lhsOperand != nil || rhsOperand != nil else { return }
        if isExemptComparand(lhs) || isExemptComparand(rhs) { return }

        let elementwise = lhsOperand?.shape == .collection || rhsOperand?.shape == .collection
        emitEqualityDiagnostic(opText: opText, node: node, elementwise: elementwise)
    }

    // MARK: - Division Checks (SequenceExpr)

    private func checkDivisionOperator(
        elements: [ExprSyntax],
        operatorIndex: Int,
        opText: String,
        node: Syntax
    ) {
        let rhsIndex = operatorIndex + 1
        guard rhsIndex < elements.count else { return }

        let divisor = elements[rhsIndex]

        // Check if divisor looks like FP or the overall expression involves FP.
        // Scalars only: a collection has no `/`, so treating one as a divisor
        // would be a finding about an expression that does not exist.
        let lhsIndex = operatorIndex - 1
        let lhsIsFP = lhsIndex >= 0 ? isDirectlyEvidencedScalar(elements[lhsIndex]) : false
        let divisorIsFP = isDirectlyEvidencedScalar(divisor)

        guard divisorIsFP || lhsIsFP else { return }

        if isNonZeroLiteral(divisor) { return }

        // Check if divisor is a known guarded variable
        if let varName = extractVariableName(divisor), isGuarded(varName) {
            return
        }

        emitDiagnostic(
            ruleId: "fp-division-unguarded",
            message: "Floating-point division without visible zero guard on divisor",
            node: node,
            suggestedFix: "Add a guard checking the divisor is not zero before dividing"
        )
    }

    // MARK: - Division Checks (InfixOperatorExpr)

    private func checkInfixDivision(
        divisor: ExprSyntax,
        node: Syntax
    ) {
        guard isDirectlyEvidencedScalar(divisor) else { return }

        if isNonZeroLiteral(divisor) { return }

        if let varName = extractVariableName(divisor), isGuarded(varName) {
            return
        }

        emitDiagnostic(
            ruleId: "fp-division-unguarded",
            message: "Floating-point division without visible zero guard on divisor",
            node: node,
            suggestedFix: "Add a guard checking the divisor is not zero before dividing"
        )
    }

    // MARK: - FP Detection Heuristics

    /// Returns the floating-point shape a *type spelling* denotes, or nil if the
    /// spelling is not a floating-point type or a collection of one.
    ///
    /// `[Double]`, `ArraySlice<Float>` and `ContiguousArray<Double>` count
    /// because `==` on them compares elementwise with `==`, which carries every
    /// caveat of the scalar operator — a NaN anywhere in either operand makes an
    /// equality assertion fail and an inequality assertion pass, regardless of
    /// what the streams actually contain.
    ///
    /// - Parameters:
    ///   - raw: The type as written in source.
    ///   - depth: Recursion budget for nested generic spellings. Guarded so the
    ///     walk terminates on any input.
    /// - Returns: The shape, or nil when the spelling says nothing useful.
    func floatingPointShape(ofTypeText raw: String, depth: Int = 0) -> FloatingPointShape? {
        guard depth < 4 else { return nil }

        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("?") || text.hasSuffix("!") {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }

        if fpTypeNames.contains(text) { return .scalar }

        // Sugared array: `[Double]`. A dictionary `[K: V]` is not one.
        if text.hasPrefix("["), text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            guard !inner.contains(":") else { return nil }
            return floatingPointShape(ofTypeText: inner, depth: depth + 1) == nil ? nil : .collection
        }

        // Spelled-out generic: `Array<Double>`, `ArraySlice<Float>`, …
        for generic in fpCollectionTypeNames where text.hasPrefix(generic + "<") && text.hasSuffix(">") {
            let inner = String(text.dropFirst(generic.count + 1).dropLast())
            return floatingPointShape(ofTypeText: inner, depth: depth + 1) == nil ? nil : .collection
        }

        return nil
    }

    /// Returns what the expression appears to evaluate to, or nil when syntax
    /// alone cannot say.
    ///
    /// - Parameters:
    ///   - expr: The expression to classify.
    ///   - depth: Recursion budget for unwrapping `try` / `await` / parentheses.
    ///     Guarded so the walk terminates on any input.
    /// - Returns: The operand, or nil when the expression's type is unknown.
    private func floatingPointOperand(of expr: ExprSyntax, depth: Int = 0) -> FloatingPointOperand? {
        guard depth < 8 else { return nil }

        // `try f()`, `await f()`, `(f())` — wrappers that say nothing about type.
        if let tryExpr = expr.as(TryExprSyntax.self) {
            return floatingPointOperand(of: tryExpr.expression, depth: depth + 1)
        }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) {
            return floatingPointOperand(of: awaitExpr.expression, depth: depth + 1)
        }
        if let tuple = expr.as(TupleExprSyntax.self),
           tuple.elements.count == 1,
           let only = tuple.elements.first,
           only.label == nil {
            return floatingPointOperand(of: only.expression, depth: depth + 1)
        }

        // Float literal: 3.14, 1.0, etc.
        if expr.is(FloatLiteralExprSyntax.self) {
            return FloatingPointOperand(shape: .scalar, evidence: .direct)
        }

        // An array literal built entirely from float literals: `[0.25, 0.5]`.
        if let array = expr.as(ArrayExprSyntax.self) {
            guard !array.elements.isEmpty else { return nil }
            let allFloat = array.elements.allSatisfy { $0.expression.is(FloatLiteralExprSyntax.self) }
            return allFloat ? FloatingPointOperand(shape: .collection, evidence: .direct) : nil
        }

        // A name bound in this or an enclosing scope.
        if let declRef = expr.as(DeclReferenceExprSyntax.self) {
            return operand(forName: declRef.baseName.text)
        }

        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            // Only the allowlisted static members are known to be the type
            // itself. `Double.dimension` is an `Int`, and syntax cannot tell.
            if let base = memberAccess.base,
               let baseRef = base.as(DeclReferenceExprSyntax.self),
               fpTypeNames.contains(baseRef.baseName.text),
               floatingPointStaticMembers.contains(memberAccess.declName.baseName.text) {
                return FloatingPointOperand(shape: .scalar, evidence: .direct)
            }
            return nil
        }

        if let funcCall = expr.as(FunctionCallExprSyntax.self),
           let calledExpr = funcCall.calledExpression.as(DeclReferenceExprSyntax.self) {
            let calleeName = calledExpr.baseName.text

            // Conversion to a floating-point type: `Double(someValue)`.
            if fpTypeNames.contains(calleeName) {
                return FloatingPointOperand(shape: .scalar, evidence: .direct)
            }

            // A call to a function this file declares, whose return type is
            // written out and unambiguous. Nothing else is resolved.
            if let returnType = fileLocalReturnTypes[calleeName],
               let shape = floatingPointShape(ofTypeText: returnType) {
                return FloatingPointOperand(shape: shape, evidence: .inferred)
            }
        }

        return nil
    }

    /// True if the expression is a scalar floating-point value on evidence
    /// written at the site — the bar the division rule holds to.
    private func isDirectlyEvidencedScalar(_ expr: ExprSyntax) -> Bool {
        guard let operand = floatingPointOperand(of: expr) else { return false }
        return operand.shape == .scalar && operand.evidence == .direct
    }

    /// Returns true if the expression is an exempt comparand (sentinel values
    /// where exact comparison is appropriate).
    private func isExemptComparand(_ expr: ExprSyntax) -> Bool {
        // `x == nil` asks whether an optional is populated. It is not a
        // floating-point comparison whatever the optional wraps, and once
        // `Double?` is read as a floating-point type — which it is — every
        // presence check on one would otherwise be a finding.
        if expr.is(NilLiteralExprSyntax.self) {
            return true
        }

        // Literal 0.0 is exempt
        if let floatLit = expr.as(FloatLiteralExprSyntax.self) {
            let text = floatLit.literal.text
            if text == "0.0" || text == "0.00" || text == "0.000" || text == ".0" {
                return true
            }
        }

        // Integer literal 0 is exempt (semantically identical to 0.0 in FP context)
        if let intLit = expr.as(IntegerLiteralExprSyntax.self) {
            if intLit.literal.text == "0" {
                return true
            }
        }

        // .zero, .nan, .infinity, .pi, etc.
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            let memberName = memberAccess.declName.baseName.text
            if exemptMemberNames.contains(memberName) {
                return true
            }
        }

        return false
    }

    // MARK: - Guard Detection

    /// Scans a syntax subtree for zero-guard patterns on variable names.
    /// Recognised patterns: `!= 0`, `> 0`, `!= 0.0`, `!= .zero`, `guard ... != 0`,
    /// `abs(x) > 0`, `abs(x) > .ulpOfOne`, `!x.isZero`.
    ///
    /// - Parameters:
    ///   - node: The subtree to scan.
    ///   - guarded: Accumulator for the names found. Guarded by the child list
    ///     running out, which it does at every leaf.
    private func collectGuardedVariables(from node: Syntax, into guarded: inout Set<String>) {
        for descendant in node.children(viewMode: .sourceAccurate) {
            // Look for SequenceExprSyntax containing guard patterns
            if let seq = descendant.as(SequenceExprSyntax.self) {
                let elements = Array(seq.elements)
                for (idx, element) in elements.enumerated() {
                    guard let binOp = element.as(BinaryOperatorExprSyntax.self) else { continue }
                    let op = binOp.operator.text

                    // Pattern: `variable != 0` / `variable != 0.0` / `variable != .zero` / `variable > 0`
                    if op == "!=" || op == ">" {
                        let lhsIdx = idx - 1
                        let rhsIdx = idx + 1
                        guard lhsIdx >= 0, rhsIdx < elements.count else { continue }

                        let lhs = elements[lhsIdx]
                        let rhs = elements[rhsIdx]
                        let isZeroCheck = isZeroExpression(rhs)
                        let isPositiveThreshold = op == ">" && isPositiveExpression(rhs)

                        if isZeroCheck || isPositiveThreshold {
                            // Direct variable: `x > 0`
                            if let varName = extractVariableName(lhs) {
                                guarded.insert(varName)
                            }
                            // Wrapped in abs(): `abs(x) > 0`
                            if let innerVar = extractAbsArgument(lhs) {
                                guarded.insert(innerVar)
                            }
                        }
                    }
                }
            }

            // Pattern: `!collection.isEmpty` implies collection.count > 0
            // Pattern: `!variable.isZero` implies variable != 0
            if let prefixOp = descendant.as(PrefixOperatorExprSyntax.self),
               prefixOp.operator.text == "!",
               let memberAccess = prefixOp.expression.as(MemberAccessExprSyntax.self) {
                let memberName = memberAccess.declName.baseName.text
                if memberName == "isEmpty", let base = memberAccess.base {
                    let countExpr = "\(base.trimmedDescription).count"
                    guarded.insert(countExpr)
                } else if memberName == "isZero", let base = memberAccess.base {
                    if let varName = extractVariableName(ExprSyntax(base)) {
                        guarded.insert(varName)
                    }
                }
            }

            // Recurse into children
            collectGuardedVariables(from: descendant, into: &guarded)
        }
    }

    /// Extracts the variable name from an `abs(variable)` call, if the expression
    /// is a call to `abs` with a single unlabelled argument.
    private func extractAbsArgument(_ expr: ExprSyntax) -> String? {
        guard let funcCall = expr.as(FunctionCallExprSyntax.self),
              let callee = funcCall.calledExpression.as(DeclReferenceExprSyntax.self),
              callee.baseName.text == "abs",
              funcCall.arguments.count == 1,
              let firstArg = funcCall.arguments.first,
              firstArg.label == nil else {
            return nil
        }
        return extractVariableName(firstArg.expression)
    }

    /// Returns true if the expression is a positive numeric literal or sentinel
    /// (e.g. `0.01`, `.ulpOfOne`, `1e-30`). Used to recognise threshold guards
    /// like `abs(x) > .ulpOfOne`.
    private func isPositiveExpression(_ expr: ExprSyntax) -> Bool {
        if let floatLit = expr.as(FloatLiteralExprSyntax.self) {
            return !isZeroExpression(ExprSyntax(floatLit))
        }
        if let intLit = expr.as(IntegerLiteralExprSyntax.self) {
            return intLit.literal.text != "0"
        }
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            let name = memberAccess.declName.baseName.text
            return name == "ulpOfOne" || name == "leastNonzeroMagnitude" || name == "leastNormalMagnitude"
        }
        return false
    }

    /// Returns true if the expression is a non-zero numeric literal (e.g. 10.0, 5.0, 2).
    private func isNonZeroLiteral(_ expr: ExprSyntax) -> Bool {
        if let floatLit = expr.as(FloatLiteralExprSyntax.self) {
            return !isZeroExpression(expr) && !floatLit.literal.text.isEmpty
        }
        if let intLit = expr.as(IntegerLiteralExprSyntax.self) {
            return intLit.literal.text != "0"
        }
        // `Float(1000)` is as constant as `1000`. Only the spelling differs, and a divisor
        // written that way was being reported as an unknown quantity needing a zero guard
        // — a guard on a literal, which no one can write meaningfully. The conversion is
        // unwrapped and the literal inside is judged instead, so `Float(0)` still fails
        // and `Double(count)` still fails: the argument has to be a literal itself.
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           Self.numericConversions.contains(callee.baseName.text),
           call.arguments.count == 1,
           let only = call.arguments.first,
           only.label == nil {
            return isNonZeroLiteral(only.expression)
        }
        return false
    }

    /// Types whose single-argument initialiser is a numeric conversion, not a computation.
    private static let numericConversions: Set<String> = [
        "Float", "Double", "CGFloat", "Float80", "Decimal",
        "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64"
    ]

    /// Returns true if the expression represents a zero value (0, 0.0, .zero).
    private func isZeroExpression(_ expr: ExprSyntax) -> Bool {
        if let intLit = expr.as(IntegerLiteralExprSyntax.self) {
            return intLit.literal.text == "0"
        }
        if let floatLit = expr.as(FloatLiteralExprSyntax.self) {
            return floatLit.literal.text == "0.0"
        }
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName.text == "zero"
        }
        return false
    }

    // MARK: - Utility

    /// Extracts a simple variable name from an expression, if it is a direct reference.
    /// Also unwraps FP type constructors like `Double(x)` to extract `x`.
    private func extractVariableName(_ expr: ExprSyntax) -> String? {
        if let declRef = expr.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text
        }
        if let memberAccess = expr.as(MemberAccessExprSyntax.self) {
            return memberAccess.trimmedDescription
        }
        if let funcCall = expr.as(FunctionCallExprSyntax.self),
           let callee = funcCall.calledExpression.as(DeclReferenceExprSyntax.self),
           fpTypeNames.contains(callee.baseName.text),
           funcCall.arguments.count == 1,
           let firstArg = funcCall.arguments.first,
           firstArg.label == nil {
            return extractVariableName(firstArg.expression)
        }
        return nil
    }

    /// Emits a diagnostic, or records an override if a suppression marker
    /// applies to the line.
    private func emitDiagnostic(
        ruleId: String,
        severity: Diagnostic.Severity = .warning,
        message: String,
        node: Syntax,
        suggestedFix: String? = nil
    ) {
        let location = node.startLocation(converter: converter)
        let line = location.line
        let column = location.column

        if let justification = suppressionJustification(forLine: line) {
            overrides.append(
                DiagnosticOverride(
                    ruleId: ruleId,
                    justification: justification,
                    filePath: filePath,
                    lineNumber: line
                )
            )
            return
        }

        diagnostics.append(
            Diagnostic(
                severity: severity,
                message: message,
                filePath: filePath,
                lineNumber: line,
                columnNumber: column,
                ruleId: ruleId,
                suggestedFix: suggestedFix
            )
        )
    }

    /// Returns the suppressing comment text for a 1-based line, if any.
    ///
    /// A marker applies to the line it sits on. It also applies to the line
    /// *below* when it sits on a comment-only line — that is how developers
    /// write a marker with a long justification, and it is the placement
    /// `// TEST-QUALITY:` has always accepted. It deliberately does **not**
    /// reach downward from a trailing marker: several hundred sites in consumer
    /// projects carry an inline `// fp-safety:disable`, and letting those bleed
    /// onto the next line would silently suppress code nobody examined.
    private func suppressionJustification(forLine line: Int) -> String? {
        let lineIndex = line - 1
        guard lineIndex >= 0, lineIndex < sourceLines.count else { return nil }

        let ownLine = sourceLines[lineIndex]
        for marker in suppressionMarkers where ownLine.contains(marker) {
            return ownLine.trimmingCharacters(in: .whitespaces)
        }

        let aboveIndex = lineIndex - 1
        guard aboveIndex >= 0 else { return nil }
        let above = sourceLines[aboveIndex].trimmingCharacters(in: .whitespaces)
        guard above.hasPrefix("//") else { return nil }
        for marker in suppressionMarkers where above.contains(marker) {
            return above
        }

        return nil
    }
}

// MARK: - Intra-file return types

/// Collects the declared return types of functions in one file.
///
/// This is the smallest amount of type information that reaches the case the
/// rule was blind to. `DistributionSeedDeterminismTests` compares two `[Double]`
/// streams for seed reproducibility, and neither local carries an annotation.
/// Reduced to the same shape, in a form this package can compile:
///
/// ```swift
/// import Testing
///
/// func block(_ draw: (UInt64) -> Double, seed: UInt64) -> [Double] {
///     (0..<4).map { draw(seed &+ UInt64($0)) }
/// }
///
/// // Neither `a` nor `b` is annotated; only `block`'s return clause is.
/// let a = block({ Double($0) / 8.0 }, seed: 42)
/// let b = block({ Double($0) / 8.0 }, seed: 42)
/// #expect(a == b)
/// ```
///
/// The helper spells its return type out and lives in the same file, so the
/// binding is recoverable without a type checker. Three limits keep it from
/// guessing:
///
/// - **Explicit return clauses only.** An inferred return type is not read back
///   from the body.
/// - **Unambiguous names only.** A name declared twice with *different* return
///   types is dropped, because choosing between overloads needs argument types
///   this collector does not have. Two declarations that agree are kept: the
///   answer does not depend on which one the compiler picks, so it is not a
///   guess. (That is the real shape here — two nested `draw` helpers, both
///   `-> [Double]`.)
/// - **One file.** Nothing is resolved across files, so a call to a helper
///   declared elsewhere stays unknown.
///
/// It is still a heuristic, and it can be wrong: a local variable or parameter
/// of function type that shadows a declared function name will be read as that
/// function. Callers bound this by only consulting the map for a *bare* callee
/// (`f(x)`, never `receiver.f(x)`) and only after scope-local bindings have had
/// their chance, so the damage is limited to a shadowed bare name.
final class FunctionReturnTypeCollector: SyntaxVisitor {
    private var returnTypes: [String: String] = [:]
    private var ambiguousNames: Set<String> = []

    /// Creates a collector.
    init() {
        super.init(viewMode: .sourceAccurate)
    }

    /// The names that resolve to exactly one written return type.
    var unambiguousReturnTypes: [String: String] {
        returnTypes.filter { !ambiguousNames.contains($0.key) }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text

        guard let returnClause = node.signature.returnClause else {
            // No written return type. It is not resolvable, and it makes any
            // sibling declaration of the same name ambiguous.
            ambiguousNames.insert(name)
            return .visitChildren
        }

        let returnType = returnClause.type.trimmedDescription
        if let existing = returnTypes[name], existing != returnType {
            ambiguousNames.insert(name)
        }
        returnTypes[name] = returnType
        return .visitChildren
    }
}
