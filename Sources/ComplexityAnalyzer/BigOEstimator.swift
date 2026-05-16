import SwiftSyntax
import SwiftParser
import SwiftOperators

/// Estimates Big-O time complexity for a function body via static analysis.
///
/// Analyzes loop nesting depth, stdlib operation costs, and combines them
/// into an overall estimate with confidence level.
struct BigOEstimator {

    struct Estimate: Sendable {
        let timeComplexity: String
        let basis: [ComplexityBasis]
        let confidence: EstimationConfidence
    }

    /// Estimates the Big-O complexity of a function body.
    static func estimate(body: CodeBlockSyntax) -> Estimate {
        let visitor = BigOVisitor()
        visitor.walk(body)

        let maxLoopDepth = visitor.maxLoopDepth
        let highestStdlibCost = visitor.highestStdlibCost
        let stdlibBasis = visitor.stdlibBasis

        var basis: [ComplexityBasis] = []
        var confidence: EstimationConfidence = .high

        if maxLoopDepth > 0 {
            basis.append(.loopNesting(depth: maxLoopDepth))
        }
        basis.append(contentsOf: stdlibBasis)

        if visitor.hasUnknownCalls {
            confidence = .medium
        }

        let loopComplexity = complexityForDepth(maxLoopDepth)
        let combined = combineComplexities(loop: loopComplexity, stdlib: highestStdlibCost)

        return Estimate(timeComplexity: combined, basis: basis, confidence: confidence)
    }

    private static func complexityForDepth(_ depth: Int) -> String {
        switch depth {
        case 0: return "O(1)"
        case 1: return "O(n)"
        case 2: return "O(n²)"
        case 3: return "O(n³)"
        default: return "O(n^\(depth))"
        }
    }

    private static func combineComplexities(loop: String, stdlib: String?) -> String {
        guard let stdlib else { return loop }

        let loopOrder = order(of: loop)
        let stdlibOrder = order(of: stdlib)

        return loopOrder >= stdlibOrder ? loop : stdlib
    }

    private static func order(of complexity: String) -> Int {
        switch complexity {
        case "O(1)": return 0
        case "O(log n)": return 1
        case "O(n)": return 2
        case "O(n log n)": return 3
        case "O(n²)": return 4
        case "O(n³)": return 5
        default:
            if complexity.contains("n^") { return 6 }
            return 2
        }
    }
}

/// Walks a function body to determine loop depth and stdlib costs.
private final class BigOVisitor: SyntaxVisitor {
    var maxLoopDepth: Int = 0
    var highestStdlibCost: String?
    var stdlibBasis: [ComplexityBasis] = []
    var hasUnknownCalls: Bool = false

    private var currentLoopDepth: Int = 0
    private var inLoopBody: Bool = false

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Loop tracking

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        currentLoopDepth += 1
        maxLoopDepth = max(maxLoopDepth, currentLoopDepth)
        let wasInLoop = inLoopBody
        inLoopBody = true
        walkStatements(in: node.body)
        inLoopBody = wasInLoop
        currentLoopDepth -= 1
        return .skipChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        currentLoopDepth += 1
        maxLoopDepth = max(maxLoopDepth, currentLoopDepth)
        let wasInLoop = inLoopBody
        inLoopBody = true
        walkStatements(in: node.body)
        inLoopBody = wasInLoop
        currentLoopDepth -= 1
        return .skipChildren
    }

    override func visit(_ node: RepeatStmtSyntax) -> SyntaxVisitorContinueKind {
        currentLoopDepth += 1
        maxLoopDepth = max(maxLoopDepth, currentLoopDepth)
        let wasInLoop = inLoopBody
        inLoopBody = true
        walkStatements(in: node.body)
        inLoopBody = wasInLoop
        currentLoopDepth -= 1
        return .skipChildren
    }

    // MARK: - Method call detection

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let methodName = node.declName.baseName.text

        if let cost = StdlibCostTable.cost(for: methodName) {
            let effectiveCost: String
            if inLoopBody {
                effectiveCost = amplify(cost, byLoopDepth: currentLoopDepth)
            } else {
                effectiveCost = cost
            }
            stdlibBasis.append(.stdlibOperation(name: methodName, cost: cost))
            updateHighestCost(effectiveCost)
        }

        return .visitChildren
    }

    // MARK: - Higher-order iteration (map, filter, forEach treated as loops)

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let methodName = memberAccess.declName.baseName.text
            let iteratingMethods: Set<String> = ["map", "flatMap", "compactMap", "filter", "forEach", "reduce"]

            if iteratingMethods.contains(methodName) {
                currentLoopDepth += 1
                maxLoopDepth = max(maxLoopDepth, currentLoopDepth)
                let wasInLoop = inLoopBody
                inLoopBody = true

                for arg in node.arguments {
                    walk(arg)
                }
                if let trailing = node.trailingClosure {
                    walk(trailing)
                }

                inLoopBody = wasInLoop
                currentLoopDepth -= 1
                return .skipChildren
            }
        }
        return .visitChildren
    }

    // MARK: - Skip nested functions

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }

    // MARK: - Helpers

    private func walkStatements(in block: CodeBlockSyntax) {
        for statement in block.statements {
            walk(statement)
        }
    }

    private func amplify(_ cost: String, byLoopDepth depth: Int) -> String {
        switch cost {
        case "O(1)":
            return BigOEstimator.complexityForDepthInternal(depth)
        case "O(n)":
            return BigOEstimator.complexityForDepthInternal(depth + 1)
        case "O(n log n)":
            if depth == 0 { return "O(n log n)" }
            return "O(n²)"
        default:
            return cost
        }
    }

    private func updateHighestCost(_ cost: String) {
        guard let current = highestStdlibCost else {
            highestStdlibCost = cost
            return
        }
        if BigOEstimator.orderInternal(of: cost) > BigOEstimator.orderInternal(of: current) {
            highestStdlibCost = cost
        }
    }
}

// Internal helpers exposed for BigOVisitor
extension BigOEstimator {
    static func complexityForDepthInternal(_ depth: Int) -> String {
        switch depth {
        case 0: return "O(1)"
        case 1: return "O(n)"
        case 2: return "O(n²)"
        case 3: return "O(n³)"
        default: return "O(n^\(depth))"
        }
    }

    static func orderInternal(of complexity: String) -> Int {
        switch complexity {
        case "O(1)": return 0
        case "O(log n)": return 1
        case "O(n)": return 2
        case "O(n log n)": return 3
        case "O(n²)": return 4
        case "O(n³)": return 5
        default:
            if complexity.contains("n^") { return 6 }
            return 2
        }
    }
}
