import SwiftSyntax
import SwiftParser
import SwiftOperators

/// Computes cognitive complexity for each function in a Swift source file.
///
/// Walks the AST and applies the SonarSource cognitive complexity algorithm:
/// - +1 for each break in linear flow (if, else, for, while, etc.)
/// - +1 nesting increment for each enclosing control-flow level
public final class CognitiveComplexityVisitor: SyntaxVisitor {
    /// Per-function complexity records accumulated during the AST walk.
    public private(set) var results: [FunctionComplexityRecord] = []

    private let filePath: String
    private let moduleName: String
    private let tree: SourceFileSyntax

    /// Creates a visitor for the given file context.
    public init(filePath: String, moduleName: String, tree: SourceFileSyntax) {
        self.filePath = filePath
        self.moduleName = moduleName
        self.tree = tree
        super.init(viewMode: .sourceAccurate)
    }

    /// Parses source, folds operators, and returns per-function cognitive complexity records.
    public static func analyze(
        source: String,
        filePath: String,
        moduleName: String
    ) -> [FunctionComplexityRecord] {
        let parsed = Parser.parse(source: source)
        let folded = OperatorTable.standardOperators.foldAll(parsed) { _ in }
        let tree = folded.as(SourceFileSyntax.self) ?? parsed
        let visitor = CognitiveComplexityVisitor(filePath: filePath, moduleName: moduleName, tree: tree)
        visitor.walk(tree)
        return visitor.results
    }

    // MARK: - Function entry points

    /// Scores a function declaration and records its complexity.
    override public func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        let scorer = FunctionScorer()
        var bigO = BigOEstimator.Estimate(timeComplexity: "O(1)", basis: [], confidence: .high)
        var patterns: [ComplexityPattern] = []

        if let body = node.body {
            scorer.walk(body)
            bigO = BigOEstimator.estimate(body: body)
            let paramTypes = PatternDetector.extractParameterTypes(from: node.signature.parameterClause.parameters)
            patterns = PatternDetector.detect(body: body, parameterTypes: paramTypes)
        }

        let converter = SourceLocationConverter(fileName: filePath, tree: tree)
        let startLoc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let endLoc = converter.location(for: node.endPositionBeforeTrailingTrivia)

        results.append(FunctionComplexityRecord(
            functionName: name,
            moduleName: moduleName,
            filePath: filePath,
            startLine: startLoc.line,
            endLine: endLoc.line,
            cognitiveComplexity: scorer.score,
            cognitiveBreakdown: scorer.increments,
            estimatedTimeComplexity: bigO.timeComplexity,
            complexityBasis: bigO.basis,
            confidence: bigO.confidence,
            detectedPatterns: patterns
        ))
        return .skipChildren
    }

    /// Scores an initializer declaration and records its complexity.
    override public func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let scorer = FunctionScorer()
        var bigO = BigOEstimator.Estimate(timeComplexity: "O(1)", basis: [], confidence: .high)
        var patterns: [ComplexityPattern] = []

        if let body = node.body {
            scorer.walk(body)
            bigO = BigOEstimator.estimate(body: body)
            let paramTypes = PatternDetector.extractParameterTypes(from: node.signature.parameterClause.parameters)
            patterns = PatternDetector.detect(body: body, parameterTypes: paramTypes)
        }

        let converter = SourceLocationConverter(fileName: filePath, tree: tree)
        let startLoc = converter.location(for: node.positionAfterSkippingLeadingTrivia)
        let endLoc = converter.location(for: node.endPositionBeforeTrailingTrivia)

        results.append(FunctionComplexityRecord(
            functionName: "init",
            moduleName: moduleName,
            filePath: filePath,
            startLine: startLoc.line,
            endLine: endLoc.line,
            cognitiveComplexity: scorer.score,
            cognitiveBreakdown: scorer.increments,
            estimatedTimeComplexity: bigO.timeComplexity,
            complexityBasis: bigO.basis,
            confidence: bigO.confidence,
            detectedPatterns: patterns
        ))
        return .skipChildren
    }
}

/// Scores a single function body for cognitive complexity.
private final class FunctionScorer: SyntaxVisitor {
    var score: Int = 0
    var increments: [CognitiveIncrement] = []
    private var nestingLevel: Int = 0

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - If / else if / else

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        addIncrement(node: "if", position: node.positionAfterSkippingLeadingTrivia, in: node)
        walkConditions(node.conditions)
        nestingLevel += 1
        walkStatements(in: node.body)
        nestingLevel -= 1

        if let elseBody = node.elseBody {
            handleElse(elseBody)
        }
        return .skipChildren
    }

    private func handleElse(_ elseBody: IfExprSyntax.ElseBody) {
        var current: IfExprSyntax.ElseBody? = elseBody
        while let body = current {
            switch body {
            case .ifExpr(let elseIf):
                addIncrement(node: "else if", position: elseIf.positionAfterSkippingLeadingTrivia, in: elseIf)
                walkConditions(elseIf.conditions)
                nestingLevel += 1
                walkStatements(in: elseIf.body)
                nestingLevel -= 1
                current = elseIf.elseBody
            case .codeBlock(let block):
                addIncrement(node: "else", position: block.positionAfterSkippingLeadingTrivia, in: block)
                nestingLevel += 1
                walkStatements(in: block)
                nestingLevel -= 1
                current = nil
            @unknown default:
                current = nil
            }
        }
    }

    // MARK: - Loops

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        addIncrement(node: "for", position: node.positionAfterSkippingLeadingTrivia, in: node)
        nestingLevel += 1
        walkStatements(in: node.body)
        nestingLevel -= 1
        return .skipChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        addIncrement(node: "while", position: node.positionAfterSkippingLeadingTrivia, in: node)
        walkConditions(node.conditions)
        nestingLevel += 1
        walkStatements(in: node.body)
        nestingLevel -= 1
        return .skipChildren
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        addIncrement(node: "repeat", position: node.positionAfterSkippingLeadingTrivia, in: node)
        nestingLevel += 1
        walkStatements(in: node.body)
        nestingLevel -= 1
        return .skipChildren
    }

    // MARK: - Guard

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        addIncrement(node: "guard", position: node.positionAfterSkippingLeadingTrivia, in: node)
        walkConditions(node.conditions)
        nestingLevel += 1
        walkStatements(in: node.body)
        nestingLevel -= 1
        return .skipChildren
    }

    // MARK: - Switch

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        addIncrement(node: "switch", position: node.positionAfterSkippingLeadingTrivia, in: node)
        nestingLevel += 1
        for caseItem in node.cases {
            walk(caseItem)
        }
        nestingLevel -= 1
        return .skipChildren
    }

    // MARK: - Do/Catch

    override func visit(_ node: DoStmtSyntax) -> SyntaxVisitorContinueKind {
        walkStatements(in: node.body)
        for catchClause in node.catchClauses {
            walk(catchClause)
        }
        return .skipChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        addIncrement(node: "catch", position: node.positionAfterSkippingLeadingTrivia, in: node)
        nestingLevel += 1
        walkStatements(in: node.body)
        nestingLevel -= 1
        return .skipChildren
    }

    // MARK: - Ternary and nil-coalescing

    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        addIncrement(node: "?:", position: node.questionMark.positionAfterSkippingLeadingTrivia, in: node)
        walk(node.condition)
        walk(node.thenExpression)
        walk(node.elseExpression)
        return .skipChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if let op = node.operator.as(BinaryOperatorExprSyntax.self) {
            let opText = op.operator.text
            if opText == "??" {
                addIncrement(node: "??", position: op.positionAfterSkippingLeadingTrivia, in: node)
                walk(node.leftOperand)
                walk(node.rightOperand)
                return .skipChildren
            }
            if opText == "&&" || opText == "||" {
                scoreLogicalChain(node)
                return .skipChildren
            }
        }
        return .visitChildren
    }

    // MARK: - Logical operator scoring

    private func scoreLogicalChain(_ topNode: InfixOperatorExprSyntax) {
        var operators: [String] = []
        collectLogicalOps(ExprSyntax(topNode), into: &operators)

        var lastOp: String?
        for op in operators {
            if op != lastOp {
                addIncrement(
                    node: op,
                    position: topNode.positionAfterSkippingLeadingTrivia,
                    in: topNode,
                    nestingOverride: 0
                )
                lastOp = op
            }
        }

        walkNonLogicalChildren(ExprSyntax(topNode))
    }

    private func collectLogicalOps(_ expr: ExprSyntax, into ops: inout [String]) {
        guard let infix = expr.as(InfixOperatorExprSyntax.self),
              let op = infix.operator.as(BinaryOperatorExprSyntax.self) else {
            return
        }
        let opText = op.operator.text
        guard opText == "&&" || opText == "||" else { return }

        collectLogicalOps(infix.leftOperand, into: &ops)
        ops.append(opText)
        collectLogicalOps(infix.rightOperand, into: &ops)
    }

    private func walkNonLogicalChildren(_ expr: ExprSyntax) {
        guard let infix = expr.as(InfixOperatorExprSyntax.self),
              let op = infix.operator.as(BinaryOperatorExprSyntax.self),
              (op.operator.text == "&&" || op.operator.text == "||") else {
            walk(expr)
            return
        }
        walkNonLogicalChildren(infix.leftOperand)
        walkNonLogicalChildren(infix.rightOperand)
    }

    // MARK: - Skip nested function declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    // MARK: - Helpers

    private func walkStatements(in block: CodeBlockSyntax) {
        for statement in block.statements {
            walk(statement)
        }
    }

    private func walkConditions(_ conditions: ConditionElementListSyntax) {
        for condition in conditions {
            walk(condition)
        }
    }

    private func addIncrement(
        node nodeName: String,
        position: AbsolutePosition,
        in syntaxNode: some SyntaxProtocol,
        nestingOverride: Int? = nil
    ) {
        let nesting = nestingOverride ?? nestingLevel
        let line = computeLine(for: position, in: syntaxNode)
        let increment = CognitiveIncrement(
            node: nodeName,
            line: line,
            baseIncrement: 1,
            nestingIncrement: nesting
        )
        score += increment.total
        increments.append(increment)
    }

    private func computeLine(for position: AbsolutePosition, in node: some SyntaxProtocol) -> Int {
        let converter = SourceLocationConverter(fileName: "", tree: node.root)
        return converter.location(for: position).line
    }
}
