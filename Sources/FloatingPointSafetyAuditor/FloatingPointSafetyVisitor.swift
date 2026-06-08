import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Constants

/// Known floating-point type names used for heuristic type detection.
private let fpTypeNames: Set<String> = [
    "Double", "Float", "CGFloat", "Float16", "Float80", "Decimal"
]

/// Member-access names that are exempt from the fp-equality rule because they
/// represent well-known sentinel values where exact comparison is intentional.
private let exemptMemberNames: Set<String> = [
    "zero", "nan", "infinity", "greatestFiniteMagnitude",
    "leastNormalMagnitude", "leastNonzeroMagnitude", "pi", "ulpOfOne"
]

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

    /// Accumulated diagnostics from the walk.
    private(set) var diagnostics: [Diagnostic] = []

    /// Variable names declared with an explicit FP type annotation in the current file.
    private var knownFPVariables: Set<String> = []

    /// Variable names initialised from a float literal (e.g. `let x = 1.0`).
    private var floatLiteralVariables: Set<String> = []

    /// Variable names whose enclosing scope contains a zero-guard expression.
    /// Collected per function body before checking divisions.
    private var guardedVariables: Set<String> = []

    /// Creates a new floating-point safety visitor.
    /// - Parameters:
    ///   - filePath: Absolute path used in diagnostic output.
    ///   - converter: Source location converter for line/column lookup.
    ///   - sourceLines: The source split by newline, for per-line disable checks.
    ///   - checkDivisionGuards: Whether to apply the `fp-division-unguarded` rule.
    init(
        filePath: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        checkDivisionGuards: Bool = true
    ) {
        self.filePath = filePath
        self.converter = converter
        self.sourceLines = sourceLines
        self.checkDivisionGuards = checkDivisionGuards
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Skip Test Files

    /// Returns true if the file path indicates a test file that should be skipped.
    private var isTestFile: Bool {
        filePath.contains("/Tests/") || filePath.hasPrefix("Tests/")
    }

    // MARK: - Variable Declaration Tracking

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }

        for binding in node.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                continue
            }
            let varName = pattern.identifier.text

            // Track explicit FP type annotations: `let x: Double`
            if let typeAnnotation = binding.typeAnnotation {
                let typeText = typeAnnotation.type.trimmedDescription
                if fpTypeNames.contains(typeText) {
                    knownFPVariables.insert(varName)
                }
            }

            // Track variables initialised from float literals: `let x = 1.0`
            if let initializer = binding.initializer {
                if initializer.value.is(FloatLiteralExprSyntax.self) {
                    floatLiteralVariables.insert(varName)
                }
            }
        }
        return .visitChildren
    }

    // MARK: - Function Body Guard Collection

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }

        // Collect guarded variables from the function body before visiting children.
        guardedVariables = []
        if let body = node.body {
            collectGuardedVariables(from: Syntax(body))
        }
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        guardedVariables = []
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        guardedVariables = []
        if let body = node.body {
            collectGuardedVariables(from: Syntax(body))
        }
        return .visitChildren
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        guardedVariables = []
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        guardedVariables = []
        if let body = node.body {
            collectGuardedVariables(from: Syntax(body))
        }
        return .visitChildren
    }

    override func visitPost(_ node: AccessorDeclSyntax) {
        guardedVariables = []
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard !isTestFile else { return .skipChildren }
        if let accessorBlock = node.accessorBlock {
            guardedVariables = []
            collectGuardedVariables(from: Syntax(accessorBlock))
        }
        return .visitChildren
    }

    override func visitPost(_ node: PatternBindingSyntax) {
        if node.accessorBlock != nil {
            guardedVariables = []
        }
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

        // Check if either side looks like floating-point
        let lhsIsFP = looksLikeFloatingPoint(lhs)
        let rhsIsFP = looksLikeFloatingPoint(rhs)

        guard lhsIsFP || rhsIsFP else { return }

        // Check exempt patterns on both sides
        if isExemptComparand(lhs) || isExemptComparand(rhs) { return }

        emitDiagnostic(
            ruleId: "fp-equality",
            message: "Exact floating-point comparison with '\(opText)'; consider using an epsilon-based comparison instead",
            node: node,
            suggestedFix: "Use abs(a - b) < epsilon instead of a \(opText) b"
        )
    }

    // MARK: - Equality Checks (InfixOperatorExpr)

    private func checkInfixEquality(
        lhs: ExprSyntax,
        rhs: ExprSyntax,
        opText: String,
        node: Syntax
    ) {
        let lhsIsFP = looksLikeFloatingPoint(lhs)
        let rhsIsFP = looksLikeFloatingPoint(rhs)

        guard lhsIsFP || rhsIsFP else { return }
        if isExemptComparand(lhs) || isExemptComparand(rhs) { return }

        emitDiagnostic(
            ruleId: "fp-equality",
            message: "Exact floating-point comparison with '\(opText)'; consider using an epsilon-based comparison instead",
            node: node,
            suggestedFix: "Use abs(a - b) < epsilon instead of a \(opText) b"
        )
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

        // Check if divisor looks like FP or the overall expression involves FP
        let lhsIndex = operatorIndex - 1
        let lhsIsFP = lhsIndex >= 0 ? looksLikeFloatingPoint(elements[lhsIndex]) : false
        let divisorIsFP = looksLikeFloatingPoint(divisor)

        guard divisorIsFP || lhsIsFP else { return }

        if isNonZeroLiteral(divisor) { return }

        // Check if divisor is a known guarded variable
        if let varName = extractVariableName(divisor), guardedVariables.contains(varName) {
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
        guard looksLikeFloatingPoint(divisor) else { return }

        if isNonZeroLiteral(divisor) { return }

        if let varName = extractVariableName(divisor), guardedVariables.contains(varName) {
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

    /// Returns true if an expression looks like it evaluates to a floating-point value.
    private func looksLikeFloatingPoint(_ expr: ExprSyntax) -> Bool {
        // Float literal: 3.14, 1.0, etc.
        if expr.is(FloatLiteralExprSyntax.self) {
            return true
        }

        // Known FP variable from type annotation
        if let varName = extractVariableName(expr) {
            if knownFPVariables.contains(varName) || floatLiteralVariables.contains(varName) {
                return true
            }
        }

        // Member access on a known FP type: Double.random(...)
        if let memberAccess = expr.as(MemberAccessExprSyntax.self),
           let base = memberAccess.base,
           let baseRef = base.as(DeclReferenceExprSyntax.self),
           fpTypeNames.contains(baseRef.baseName.text) {
            return true
        }

        // Function call on a known FP type: Double(someValue)
        if let funcCall = expr.as(FunctionCallExprSyntax.self),
           let calledExpr = funcCall.calledExpression.as(DeclReferenceExprSyntax.self),
           fpTypeNames.contains(calledExpr.baseName.text) {
            return true
        }

        return false
    }

    /// Returns true if the expression is an exempt comparand (sentinel values
    /// where exact comparison is appropriate).
    private func isExemptComparand(_ expr: ExprSyntax) -> Bool {
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
    private func collectGuardedVariables(from node: Syntax) {
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
                                guardedVariables.insert(varName)
                            }
                            // Wrapped in abs(): `abs(x) > 0`
                            if let innerVar = extractAbsArgument(lhs) {
                                guardedVariables.insert(innerVar)
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
                    guardedVariables.insert(countExpr)
                } else if memberName == "isZero", let base = memberAccess.base {
                    if let varName = extractVariableName(ExprSyntax(base)) {
                        guardedVariables.insert(varName)
                    }
                }
            }

            // Recurse into children
            collectGuardedVariables(from: descendant)
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
        return false
    }

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

    /// Emits a diagnostic if the line does not contain a disable comment.
    private func emitDiagnostic(
        ruleId: String,
        message: String,
        node: Syntax,
        suggestedFix: String? = nil
    ) {
        let location = node.startLocation(converter: converter)
        let line = location.line
        let column = location.column

        // Per-line disable: skip if the source line contains the disable comment
        let lineIndex = line - 1
        if lineIndex >= 0, lineIndex < sourceLines.count {
            if sourceLines[lineIndex].contains("// fp-safety:disable") {
                return
            }
        }

        diagnostics.append(
            Diagnostic(
                severity: .warning,
                message: message,
                filePath: filePath,
                lineNumber: line,
                columnNumber: column,
                ruleId: ruleId,
                suggestedFix: suggestedFix
            )
        )
    }
}
