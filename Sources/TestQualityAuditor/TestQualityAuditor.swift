import Foundation
import QualityGateCore
import SwiftSyntax
import SwiftParser

/// Scans Swift test files for quality anti-patterns.
///
/// Detects:
/// - Exact equality (`==`/`!=`) on floating-point literals inside `#expect`
/// - `try!` in test code
/// - Unseeded randomness (`.random`, `SystemRandomNumberGenerator`)
/// - `@Test` functions with no assertions (`#expect` or `#require`)
/// - Weak assertions (`!= 0`, `!= nil`) without quantitative bounds
///
/// ## Usage
///
/// ```swift
/// let auditor = TestQualityAuditor()
/// let result = try await auditor.check(configuration: config)
/// ```
public struct TestQualityAuditor: QualityChecker, Sendable {
    /// Unique identifier for this checker.
    public let id = "test-quality"

    /// Human-readable name for this checker.
    public let name = "Test Quality Auditor"

    /// Creates a new TestQualityAuditor instance.
    public init() {}

    /// Run the test quality audit on the Tests/ directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let testsPath = (currentDir as NSString).appendingPathComponent("Tests")

        var allDiagnostics: [Diagnostic] = []
        var allOverrides: [DiagnosticOverride] = []

        if fileManager.fileExists(atPath: testsPath) {
            let result = try await auditDirectory(
                at: testsPath,
                configuration: configuration
            )
            allDiagnostics.append(contentsOf: result.diagnostics)
            allOverrides.append(contentsOf: result.overrides)
        }

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = allDiagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: allDiagnostics,
            overrides: allOverrides,
            duration: duration
        )
    }

    /// Audit a single source code string (useful for testing).
    ///
    /// - Parameters:
    ///   - source: The Swift source code to audit.
    ///   - fileName: The name of the file (for diagnostics).
    ///   - configuration: The project configuration.
    /// - Returns: A check result with any violations found.
    public func auditSource(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let result = auditSourceCode(
            source,
            fileName: fileName,
            configuration: configuration
        )

        let duration = ContinuousClock.now - startTime
        let status: CheckResult.Status = result.diagnostics.isEmpty ? .passed : .failed

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: result.diagnostics,
            overrides: result.overrides,
            duration: duration
        )
    }

    // MARK: - Private Implementation

    private func auditDirectory(
        at path: String,
        configuration: Configuration
    ) async throws -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let fileManager = FileManager.default
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []

        guard let enumerator = fileManager.enumerator(atPath: path) else {
            return ([], [])
        }

        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".swift") else { continue }

            let fullPath = (path as NSString).appendingPathComponent(relativePath)

            if shouldExclude(path: fullPath, patterns: configuration.excludePatterns) {
                continue
            }

            do {
                let source = try String(contentsOfFile: fullPath, encoding: .utf8)
                let result = auditSourceCode(
                    source,
                    fileName: fullPath,
                    configuration: configuration
                )
                diagnostics.append(contentsOf: result.diagnostics)
                overrides.append(contentsOf: result.overrides)
            } catch {
                continue
            }
        }

        return (diagnostics, overrides)
    }

    private func shouldExclude(path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if pathMatches(path: path, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private func pathMatches(path: String, pattern: String) -> Bool {
        if pattern.contains("**") {
            let component = pattern.replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
            return path.contains(component)
        }
        return path.contains(pattern.replacingOccurrences(of: "*", with: ""))
    }

    private func auditSourceCode(
        _ source: String,
        fileName: String,
        configuration: Configuration
    ) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let sourceFile = Parser.parse(source: source)

        let visitor = TestQualityVisitor(
            fileName: fileName,
            source: source,
            exemptionPatterns: configuration.safetyExemptions + ["// TEST-QUALITY:"]
        )
        visitor.walk(sourceFile)

        return (visitor.diagnostics, visitor.overrides)
    }
}

// MARK: - Syntax Visitor

private final class TestQualityVisitor: SyntaxVisitor {
    let fileName: String
    let source: String
    let exemptionPatterns: [String]
    let sourceLines: [String]
    var diagnostics: [Diagnostic] = []
    var overrides: [DiagnosticOverride] = []

    /// Tracks whether we're inside a `@Test`-attributed function.
    private var currentTestFunctionName: String?
    private var currentTestFunctionLine: Int?
    private var currentTestHasAssertion: Bool = false

    /// Whether the file imports the Testing framework.
    private var importsTestingFramework: Bool = false

    /// Whether we're inside a `#expect` or `#require` macro expansion.
    private var insideExpectMacro: Bool = false

    init(fileName: String, source: String, exemptionPatterns: [String]) {
        self.fileName = fileName
        self.source = source
        self.exemptionPatterns = exemptionPatterns
        self.sourceLines = source.components(separatedBy: .newlines)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Import Detection

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let moduleName = node.path.map { $0.name.text }.joined(separator: ".")
        if moduleName == "Testing" {
            importsTestingFramework = true
        }
        return .visitChildren
    }

    // MARK: - @Test Function Tracking

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let hasTestAttribute = node.attributes.contains { attr in
            if let identAttr = attr.as(AttributeSyntax.self) {
                let attrName: String
                if let identifier = identAttr.attributeName.as(IdentifierTypeSyntax.self) {
                    attrName = identifier.name.text
                } else {
                    attrName = identAttr.attributeName.description.trimmingCharacters(in: .whitespaces)
                }
                return attrName == "Test"
            }
            return false
        }

        if hasTestAttribute {
            currentTestFunctionName = node.name.text
            let location = node.startLocation(
                converter: SourceLocationConverter(fileName: fileName, tree: node.root)
            )
            currentTestFunctionLine = location.line
            currentTestHasAssertion = false
        }

        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        // When leaving a @Test function, check if it had any assertions.
        if let testName = currentTestFunctionName, !currentTestHasAssertion {
            let line = currentTestFunctionLine ?? 1
            if let override = overrideIfExempted(line: line, ruleId: "missing-assertion") {
                overrides.append(override)
            } else {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "Test function '\(testName)' has no #expect or #require assertions.",
                    filePath: fileName,
                    lineNumber: line,
                    columnNumber: nil,
                    ruleId: "missing-assertion",
                    suggestedFix: "Add #expect or #require assertions to validate behavior"
                ))
            }
        }
        currentTestFunctionName = nil
        currentTestFunctionLine = nil
        currentTestHasAssertion = false
    }

    // MARK: - Force Try Detection

    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        if node.questionOrExclamationMark?.tokenKind == .exclamationMark {
            let location = node.startLocation(
                converter: SourceLocationConverter(fileName: fileName, tree: node.root)
            )
            let line = location.line

            if let override = overrideIfExempted(line: line, ruleId: "force-try-in-test") {
                overrides.append(override)
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "Force try (try!) in test code. Use do/catch with #expect(throws:) or propagate with 'throws'.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "force-try-in-test",
                suggestedFix: "Replace try! with #expect(throws: ErrorType.self) { try expression } or mark test as throws"
            ))
        }

        return .visitChildren
    }

    // MARK: - #expect / #require Macro Detection

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        let macroName = node.macroName.text
        if macroName == "expect" || macroName == "require" {
            currentTestHasAssertion = true

            // Analyze the arguments for anti-patterns.
            let prevInsideExpect = insideExpectMacro
            insideExpectMacro = true
            analyzeExpectArguments(node)
            insideExpectMacro = prevInsideExpect
        }
        return .visitChildren
    }

    // MARK: - Unseeded Randomness Detection

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "random" {
            let location = node.startLocation(
                converter: SourceLocationConverter(fileName: fileName, tree: node.root)
            )
            let line = location.line

            if let override = overrideIfExempted(line: line, ruleId: "unseeded-random") {
                overrides.append(override)
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "Unseeded .random usage in test code. Tests must be deterministic.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "unseeded-random",
                suggestedFix: "Inject a SeededGenerator or validate distributional invariants only"
            ))
        }

        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if node.baseName.text == "SystemRandomNumberGenerator" {
            let location = node.startLocation(
                converter: SourceLocationConverter(fileName: fileName, tree: node.root)
            )
            let line = location.line

            if let override = overrideIfExempted(line: line, ruleId: "unseeded-random") {
                overrides.append(override)
                return .visitChildren
            }

            diagnostics.append(Diagnostic(
                severity: .warning,
                message: "SystemRandomNumberGenerator in test code produces non-deterministic results.",
                filePath: fileName,
                lineNumber: line,
                columnNumber: location.column,
                ruleId: "unseeded-random",
                suggestedFix: "Use a SeededGenerator with a fixed seed for reproducible tests"
            ))
        }

        return .visitChildren
    }

    // MARK: - Expect Argument Analysis

    private func analyzeExpectArguments(_ node: MacroExpansionExprSyntax) {
        // Walk the argument expressions looking for anti-patterns.
        for argument in node.arguments {
            let expr = argument.expression
            analyzeExpressionForAntiPatterns(expr, in: node)
        }
    }

    /// Analyzes expressions inside #expect for anti-patterns.
    ///
    /// Handles both `SequenceExprSyntax` (pre-fold) and `InfixOperatorExprSyntax` (post-fold)
    /// representations of binary expressions.
    private func analyzeExpressionForAntiPatterns(
        _ expr: ExprSyntax,
        in macroNode: MacroExpansionExprSyntax
    ) {
        // Handle SequenceExprSyntax: e.g., `result == 0.3989`
        if let sequence = expr.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)

            for (index, element) in elements.enumerated() {
                // Look for binary operators
                if let binOp = element.as(BinaryOperatorExprSyntax.self) {
                    let opText = binOp.operator.text

                    // Check for exact double equality
                    if opText == "==" || opText == "!=" {
                        checkExactDoubleEquality(
                            elements: elements,
                            operatorIndex: index,
                            opText: opText,
                            macroNode: macroNode
                        )

                        // Check for weak assertions: `!= 0` or `!= nil`
                        if opText == "!=" {
                            checkWeakAssertion(
                                elements: elements,
                                operatorIndex: index,
                                macroNode: macroNode
                            )
                        }
                    }
                }
            }
        }

        // Handle InfixOperatorExprSyntax (if operator folding has occurred)
        if let infix = expr.as(InfixOperatorExprSyntax.self),
           let binOp = infix.operator.as(BinaryOperatorExprSyntax.self) {
            let opText = binOp.operator.text

            if opText == "==" || opText == "!=" {
                let lhs = infix.leftOperand
                let rhs = infix.rightOperand
                let hasFloatLiteral = lhs.is(FloatLiteralExprSyntax.self)
                    || rhs.is(FloatLiteralExprSyntax.self)

                if hasFloatLiteral && opText == "==" {
                    emitExactDoubleEqualityDiagnostic(at: macroNode)
                }

                if opText == "!=" {
                    let rhsIsZero = rhs.as(IntegerLiteralExprSyntax.self)?.literal.text == "0"
                    let rhsIsNil = rhs.is(NilLiteralExprSyntax.self)
                    let lhsIsZero = lhs.as(IntegerLiteralExprSyntax.self)?.literal.text == "0"
                    let lhsIsNil = lhs.is(NilLiteralExprSyntax.self)

                    if rhsIsZero || rhsIsNil || lhsIsZero || lhsIsNil {
                        emitWeakAssertionDiagnostic(at: macroNode)
                    }
                }
            }
        }
    }

    private func checkExactDoubleEquality(
        elements: [ExprSyntax],
        operatorIndex: Int,
        opText: String,
        macroNode: MacroExpansionExprSyntax
    ) {
        guard opText == "==" else { return }

        // Check LHS and RHS for float literals.
        let lhsIndex = operatorIndex - 1
        let rhsIndex = operatorIndex + 1

        var hasFloatLiteral = false

        if lhsIndex >= 0, elements[lhsIndex].is(FloatLiteralExprSyntax.self) {
            hasFloatLiteral = true
        }
        if rhsIndex < elements.count, elements[rhsIndex].is(FloatLiteralExprSyntax.self) {
            hasFloatLiteral = true
        }

        if hasFloatLiteral {
            emitExactDoubleEqualityDiagnostic(at: macroNode)
        }
    }

    private func checkWeakAssertion(
        elements: [ExprSyntax],
        operatorIndex: Int,
        macroNode: MacroExpansionExprSyntax
    ) {
        let rhsIndex = operatorIndex + 1
        let lhsIndex = operatorIndex - 1

        var isWeak = false

        // Check RHS for 0 or nil
        if rhsIndex < elements.count {
            if let intLit = elements[rhsIndex].as(IntegerLiteralExprSyntax.self),
               intLit.literal.text == "0" {
                isWeak = true
            }
            if elements[rhsIndex].is(NilLiteralExprSyntax.self) {
                isWeak = true
            }
        }

        // Check LHS for 0 or nil (reversed comparison)
        if lhsIndex >= 0 {
            if let intLit = elements[lhsIndex].as(IntegerLiteralExprSyntax.self),
               intLit.literal.text == "0" {
                isWeak = true
            }
            if elements[lhsIndex].is(NilLiteralExprSyntax.self) {
                isWeak = true
            }
        }

        if isWeak {
            emitWeakAssertionDiagnostic(at: macroNode)
        }
    }

    private func emitExactDoubleEqualityDiagnostic(at node: some SyntaxProtocol) {
        let location = node.startLocation(
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        let line = location.line

        if let override = overrideIfExempted(line: line, ruleId: "exact-double-equality") {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .error,
            message: "Exact equality (==) on floating-point literal. Use tolerance: abs(a - b) < epsilon.",
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: "exact-double-equality",
            suggestedFix: "Replace #expect(a == 0.3989) with #expect(abs(a - 0.3989) < 1e-6)"
        ))
    }

    private func emitWeakAssertionDiagnostic(at node: some SyntaxProtocol) {
        let location = node.startLocation(
            converter: SourceLocationConverter(fileName: fileName, tree: node.root)
        )
        let line = location.line

        if let override = overrideIfExempted(line: line, ruleId: "weak-assertion") {
            overrides.append(override)
            return
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: "Weak assertion: != 0 or != nil does not validate correctness. Assert quantitative bounds.",
            filePath: fileName,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: "weak-assertion",
            suggestedFix: "Replace != 0 with a specific expected value or range check"
        ))
    }

    // MARK: - Exemption Checking

    private func overrideIfExempted(line: Int, ruleId: String) -> DiagnosticOverride? {
        let linesToCheck = [line - 1, line]
            .filter { $0 >= 1 && $0 <= sourceLines.count }

        for lineNum in linesToCheck {
            let lineContent = sourceLines[lineNum - 1]
            for pattern in exemptionPatterns {
                if lineContent.contains(pattern) {
                    return DiagnosticOverride(
                        ruleId: ruleId,
                        justification: lineContent.trimmingCharacters(in: .whitespaces),
                        filePath: fileName,
                        lineNumber: line
                    )
                }
            }
        }

        return nil
    }
}
