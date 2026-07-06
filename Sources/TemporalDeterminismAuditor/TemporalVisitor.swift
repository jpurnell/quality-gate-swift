import Foundation
import QualityGateCore
import SwiftSyntax

// MARK: - Constants

/// Type names whose `.now` reads a wall clock.
private let clockTypeNames: Set<String> = ["ContinuousClock", "SuspendingClock", "Date"]

/// `DispatchTime`-family types whose `.now()` reads a wall clock.
private let dispatchTimeTypes: Set<String> = ["DispatchTime", "DispatchWallTime"]

/// Global C functions that read a wall/monotonic clock.
private let globalTimeFunctions: Set<String> = [
    "CFAbsoluteTimeGetCurrent", "mach_absolute_time", "mach_continuous_time"
]

/// Instance methods that yield a measured elapsed interval.
private let elapsedMethodNames: Set<String> = [
    "timeIntervalSince", "timeIntervalSinceNow", "timeIntervalSinceReferenceDate"
]

/// Regex fragments (lowercased) marking a type as a simulated/test-double source.
private let simulationTypeMarkers: [String] = [
    "simulation", "simulated", "synthetic", "mock", "fake", "stub", "replay", "fixture"
]

/// Relational operators used in timing threshold assertions.
private let relationalOperators: Set<String> = ["<", ">", "<=", ">="]

/// XCTest assertions that are themselves a relational comparison.
private let comparisonXCTAsserts: Set<String> = [
    "XCTAssertLessThan", "XCTAssertLessThanOrEqual",
    "XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual"
]

/// XCTest assertions whose single argument is a boolean expression.
private let booleanXCTAsserts: Set<String> = ["XCTAssert", "XCTAssertTrue", "XCTAssertFalse"]

// MARK: - Visitor

/// Walks a Swift syntax tree detecting wall-clock nondeterminism.
///
/// - **temporal-simulated-wall-clock**: a wall-clock read used as a timestamp
///   value inside a simulation/synthetic/mock type.
/// - **temporal-wall-clock-assertion**: a test assertion comparing measured
///   elapsed wall-clock time against a numeric threshold.
final class TemporalVisitor: SyntaxVisitor {
    let filePath: String
    let converter: SourceLocationConverter
    let sourceLines: [String]
    let config: TemporalDeterminismConfig

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var overrides: [DiagnosticOverride] = []

    /// Stack of enclosing type declarations: whether each is a simulation type.
    private var simulationTypeStack: [Bool] = []
    /// Stack of enclosing functions: whether each is a test function.
    private var testFunctionStack: [Bool] = []
    /// Current-function name, for exempt-function checks.
    private var functionNameStack: [String] = []
    /// Per-function set of local variable names bound to an elapsed-time expression.
    private var elapsedVarsStack: [Set<String>] = []

    init(
        filePath: String,
        converter: SourceLocationConverter,
        sourceLines: [String],
        config: TemporalDeterminismConfig
    ) {
        self.filePath = filePath
        self.converter = converter
        self.sourceLines = sourceLines
        self.config = config
        super.init(viewMode: .sourceAccurate)
    }

    private var inSimulationType: Bool { simulationTypeStack.contains(true) }
    private var inTestFunction: Bool { testFunctionStack.last == true }

    private func currentElapsedVars() -> Set<String> {
        elapsedVarsStack.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    // MARK: - Type tracking

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(name: node.name.text, inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { simulationTypeStack.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(name: node.name.text, inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { simulationTypeStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(name: node.name.text, inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { simulationTypeStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(name: node.name.text, inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { simulationTypeStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        pushType(name: node.extendedType.trimmedDescription, inheritance: node.inheritanceClause)
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { simulationTypeStack.removeLast() }

    private func pushType(name: String, inheritance: InheritanceClauseSyntax?) {
        let lowerName = name.lowercased()
        var isSim = simulationTypeMarkers.contains { lowerName.contains($0) }
        if let inheritance {
            for inherited in inheritance.inheritedTypes {
                let lower = inherited.type.trimmedDescription.lowercased()
                if simulationTypeMarkers.contains(where: { lower.contains($0) }) { isSim = true }
            }
        }
        if config.exemptTypes.contains(where: { name.contains($0) }) { isSim = false }
        simulationTypeStack.append(isSim)
    }

    // MARK: - Function tracking

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let hasTestAttribute = node.attributes.contains { attr in
            attr.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Test"
        }
        let isTest = hasTestAttribute || name.hasPrefix("test")
        testFunctionStack.append(isTest)
        functionNameStack.append(name)
        elapsedVarsStack.append([])
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        testFunctionStack.removeLast()
        functionNameStack.removeLast()
        elapsedVarsStack.removeLast()
    }

    // MARK: - Rule 1: simulated wall-clock timestamps

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Rule 2 first: XCTest-style assertions are function calls.
        if config.flagWallClockAssertion, inTestFunction, !isExemptFunction {
            checkXCTAssert(node)
        }

        // Rule 1: labeled argument whose value is a wall-clock read.
        if config.flagSimulatedWallClock, inSimulationType {
            for arg in node.arguments {
                guard let label = arg.label?.text, isTimestampLabel(label) else { continue }
                if wallClockRead(arg.expression) {
                    emit(
                        ruleId: "temporal-simulated-wall-clock",
                        message: "Simulated source stamps wall-clock time into `\(label):`; sample spacing will track scheduler jitter, not the intended interval.",
                        node: Syntax(arg.expression),
                        isAssertion: false,
                        suggestedFix: "Derive the timestamp from a fixed logical origin advanced by elapsed synthetic time"
                    )
                }
            }
        }
        return .visitChildren
    }

    // MARK: - Rule 1: property assignment form (self.timestamp = .now)

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        if config.flagSimulatedWallClock, inSimulationType {
            let elements = Array(node.elements)
            if let assignIdx = elements.firstIndex(where: { $0.is(AssignmentExprSyntax.self) }),
               assignIdx > 0, assignIdx + 1 < elements.count {
                let lhs = elements[assignIdx - 1]
                let rhs = elements[assignIdx + 1]
                if isTimestampTargetName(lhs), wallClockRead(rhs) {
                    emit(
                        ruleId: "temporal-simulated-wall-clock",
                        message: "Simulated source assigns wall-clock time to a timestamp property; use a logical clock so output is reproducible.",
                        node: Syntax(rhs),
                        isAssertion: false,
                        suggestedFix: "Assign a timestamp derived from a fixed logical origin instead of a wall-clock read"
                    )
                }
            }
        }
        return .visitChildren
    }

    // MARK: - Rule 2: elapsed-time variable bindings

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard inTestFunction, !elapsedVarsStack.isEmpty else { return .visitChildren }
        for binding in node.bindings {
            guard let initializer = binding.initializer?.value else { continue }
            if isElapsedExpr(initializer),
               let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                elapsedVarsStack[elapsedVarsStack.count - 1].insert(pattern.identifier.text)
            }
        }
        return .visitChildren
    }

    // MARK: - Rule 2: #expect / #require assertions

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        guard config.flagWallClockAssertion, inTestFunction, !isExemptFunction else { return .visitChildren }
        let macroName = node.macroName.text
        guard macroName == "expect" || macroName == "require" else { return .visitChildren }
        for arg in node.arguments where timingViolation(in: arg.expression) {
            emitAssertionDiagnostic(node: Syntax(node))
            break
        }
        return .visitChildren
    }

    private func checkXCTAssert(_ node: FunctionCallExprSyntax) {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self) else { return }
        let name = callee.baseName.text
        if comparisonXCTAsserts.contains(name) {
            for arg in node.arguments where exprInvolvesElapsed(arg.expression) {
                emitAssertionDiagnostic(node: Syntax(node)); return
            }
        } else if booleanXCTAsserts.contains(name) {
            if let first = node.arguments.first, timingViolation(in: first.expression) {
                emitAssertionDiagnostic(node: Syntax(node))
            }
        }
    }

    // MARK: - Detection helpers

    /// Returns true if the expression reads a wall clock.
    private func wallClockRead(_ expr: ExprSyntax) -> Bool {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            let memberName = member.declName.baseName.text
            if memberName == "systemUptime" { return true }
            if memberName == "now", let base = member.base {
                if let ref = base.as(DeclReferenceExprSyntax.self) {
                    if clockTypeNames.contains(ref.baseName.text) { return true }
                    if ref.baseName.text.lowercased().contains("clock") { return true }
                }
                if let call = base.as(FunctionCallExprSyntax.self),
                   let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
                   clockTypeNames.contains(callee.baseName.text) {
                    return true
                }
            }
            return false
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                if callee.baseName.text == "Date", call.arguments.isEmpty { return true }
                if globalTimeFunctions.contains(callee.baseName.text) { return true }
            }
            if let calleeMember = call.calledExpression.as(MemberAccessExprSyntax.self),
               calleeMember.declName.baseName.text == "now",
               let base = calleeMember.base?.as(DeclReferenceExprSyntax.self),
               dispatchTimeTypes.contains(base.baseName.text) {
                return true
            }
        }
        return false
    }

    /// Returns true if the expression measures an elapsed wall-clock interval.
    private func isElapsedExpr(_ expr: ExprSyntax) -> Bool {
        if let infix = expr.as(InfixOperatorExprSyntax.self),
           let op = infix.operator.as(BinaryOperatorExprSyntax.self), op.operator.text == "-" {
            if wallClockRead(infix.leftOperand) || wallClockRead(infix.rightOperand) { return true }
        }
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            for (i, e) in elems.enumerated() {
                guard let op = e.as(BinaryOperatorExprSyntax.self), op.operator.text == "-" else { continue }
                if i > 0, wallClockRead(elems[i - 1]) { return true }
                if i + 1 < elems.count, wallClockRead(elems[i + 1]) { return true }
            }
        }
        if let member = expr.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "timeIntervalSinceNow" {
            return true
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let m = member.declName.baseName.text
            if elapsedMethodNames.contains(m) { return true }
            // start.duration(to: .now) / start.distance(to: end)
            if m == "duration" || m == "distance" {
                for arg in call.arguments where arg.label?.text == "to" {
                    if wallClockRead(arg.expression) || isDotNow(arg.expression) { return true }
                }
            }
        }
        return false
    }

    /// True for a bare `.now` implicit-member expression (e.g. `duration(to: .now)`).
    private func isDotNow(_ expr: ExprSyntax) -> Bool {
        guard let member = expr.as(MemberAccessExprSyntax.self) else { return false }
        return member.base == nil && member.declName.baseName.text == "now"
    }

    /// True if the expression (transitively) involves a measured elapsed interval
    /// or references a variable bound to one.
    private func exprInvolvesElapsed(_ expr: ExprSyntax, depth: Int = 0) -> Bool {
        if depth > 6 { return false }
        if isElapsedExpr(expr) { return true }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            return currentElapsedVars().contains(ref.baseName.text)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self), callee.baseName.text == "abs" {
                for arg in call.arguments where exprInvolvesElapsed(arg.expression, depth: depth + 1) { return true }
            }
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self) {
            return exprInvolvesElapsed(infix.leftOperand, depth: depth + 1)
                || exprInvolvesElapsed(infix.rightOperand, depth: depth + 1)
        }
        if let seq = expr.as(SequenceExprSyntax.self) {
            for e in seq.elements where exprInvolvesElapsed(e, depth: depth + 1) { return true }
        }
        if let tuple = expr.as(TupleExprSyntax.self) {
            for el in tuple.elements where exprInvolvesElapsed(el.expression, depth: depth + 1) { return true }
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            return exprInvolvesElapsed(base, depth: depth + 1)
        }
        return false
    }

    /// True if the assertion argument compares an elapsed value against a threshold.
    private func timingViolation(in expr: ExprSyntax) -> Bool {
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            for (i, e) in elems.enumerated() {
                guard let op = e.as(BinaryOperatorExprSyntax.self),
                      relationalOperators.contains(op.operator.text) else { continue }
                if i > 0, exprInvolvesElapsed(elems[i - 1]) { return true }
                if i + 1 < elems.count, exprInvolvesElapsed(elems[i + 1]) { return true }
            }
        }
        if let infix = expr.as(InfixOperatorExprSyntax.self),
           let op = infix.operator.as(BinaryOperatorExprSyntax.self),
           relationalOperators.contains(op.operator.text) {
            if exprInvolvesElapsed(infix.leftOperand) || exprInvolvesElapsed(infix.rightOperand) { return true }
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let inner = tuple.elements.first?.expression {
            return timingViolation(in: inner)
        }
        return false
    }

    // MARK: - Name helpers

    private func isTimestampLabel(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("time") || l.contains("date") || l == "at" || l.hasSuffix("at")
            || l == "when" || l == "instant" || l == "moment"
    }

    private func isTimestampTargetName(_ expr: ExprSyntax) -> Bool {
        let name: String
        if let member = expr.as(MemberAccessExprSyntax.self) {
            name = member.declName.baseName.text
        } else if let ref = expr.as(DeclReferenceExprSyntax.self) {
            name = ref.baseName.text
        } else {
            return false
        }
        let l = name.lowercased()
        return l.contains("timestamp") || l.contains("time") || l.contains("date")
    }

    private var isExemptFunction: Bool {
        guard let name = functionNameStack.last else { return false }
        return config.exemptFunctions.contains(name)
    }

    // MARK: - Emission

    private func emitAssertionDiagnostic(node: Syntax) {
        emit(
            ruleId: "temporal-wall-clock-assertion",
            message: "Assertion compares measured wall-clock elapsed time against a threshold; this flakes under load. Assert on logical time, or mark an intentional perf test with `// TIMING:`.",
            node: node,
            isAssertion: true,
            suggestedFix: "Drive timing from a controllable clock, or move the wall-clock threshold to a load-tolerant perf suite marked `// TIMING:`"
        )
    }

    private func emit(
        ruleId: String,
        message: String,
        node: Syntax,
        isAssertion: Bool,
        suggestedFix: String?
    ) {
        let location = node.startLocation(converter: converter)
        let line = location.line
        let lineIndex = line - 1

        // Per-line exemptions: `// temporal:exempt` (both rules), `// TIMING:` (assertion rule).
        for checkLine in [lineIndex, lineIndex - 1] where checkLine >= 0 && checkLine < sourceLines.count {
            let content = sourceLines[checkLine]
            let exemptComment = content.contains("// temporal:exempt")
            let timingComment = isAssertion && content.contains("// TIMING:")
            if exemptComment || timingComment {
                overrides.append(DiagnosticOverride(
                    ruleId: ruleId,
                    justification: content.trimmingCharacters(in: .whitespaces),
                    filePath: filePath,
                    lineNumber: line
                ))
                return
            }
        }

        diagnostics.append(Diagnostic(
            severity: .warning,
            message: message,
            filePath: filePath,
            lineNumber: line,
            columnNumber: location.column,
            ruleId: ruleId,
            suggestedFix: suggestedFix
        ))
    }
}
