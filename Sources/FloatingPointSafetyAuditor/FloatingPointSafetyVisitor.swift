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
    /// Recognised patterns: `!= 0`, `> 0`, `!= 0.0`, `!= .zero`, `guard ... != 0`.
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

                        let rhs = elements[rhsIdx]
                        let isZeroCheck = isZeroExpression(rhs)

                        if isZeroCheck, let varName = extractVariableName(elements[lhsIdx]) {
                            guardedVariables.insert(varName)
                        }
                    }
                }
            }

            // Recurse into children
            collectGuardedVariables(from: descendant)
        }
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
    private func extractVariableName(_ expr: ExprSyntax) -> String? {
        if let declRef = expr.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text
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
