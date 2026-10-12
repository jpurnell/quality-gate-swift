import Foundation
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

    /// Estimates the Big-O complexity of a function body, consulting user-declared costs first.
    ///
    /// - Parameters:
    ///   - body: The function body to analyze.
    ///   - userCosts: User-declared pattern-to-cost mappings from configuration.
    /// - Returns: The estimated complexity with basis and confidence.
    static func estimate(body: CodeBlockSyntax, userCosts: [String: String] = [:]) -> Estimate {
        let visitor = BigOVisitor(userCosts: userCosts)
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
    private let userCosts: [String: String]

    init(userCosts: [String: String] = [:]) {
        self.userCosts = userCosts
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

        // Not every `.name` is a call on a collection. An implicit member (`case .first:`,
        // `return .last`) has no receiver at all — it is an enum case or a static member —
        // and `map` on an `as?` result is `Optional.map`, which runs at most once. Both were
        // costed as O(n) by name alone: BioFeedbackKit-HealthKit's `case .first:` and
        // `(sample as? Series).map { … }` each made a function read as O(n²) from its caller.
        guard let base = node.base, !Self.isOptionalProducing(base) else {
            return .visitChildren
        }

        // Build a qualified name (e.g., "receiver.method") for user cost matching
        let qualifiedName = "\(base.description.trimmingCharacters(in: .whitespacesAndNewlines)).\(methodName)"

        if let cost = StdlibCostTable.cost(for: qualifiedName, userCosts: userCosts) {
            let effectiveCost: String
            if inLoopBody {
                effectiveCost = amplify(cost, byLoopDepth: currentLoopDepth)
            } else {
                effectiveCost = cost
            }
            stdlibBasis.append(.stdlibOperation(name: methodName, cost: cost))
            updateHighestCost(effectiveCost)
        } else if let cost = StdlibCostTable.cost(for: methodName, userCosts: userCosts) {
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
        if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self),
           let base = memberAccess.base, !Self.isOptionalProducing(base) {
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

    /// Whether `expression` is a parenthesised conditional cast, `(x as? T)` — whose value
    /// is an Optional, so `.map` / `.flatMap` on it run their closure at most once.
    ///
    /// Recognised both folded (`AsExprSyntax`) and as the parser leaves it
    /// (`SequenceExprSyntax` holding an `UnresolvedAsExprSyntax`).
    static func isOptionalProducing(_ expression: ExprSyntax) -> Bool {
        guard let tuple = expression.as(TupleExprSyntax.self),
              tuple.elements.count == 1,
              let inner = tuple.elements.first?.expression else {
            return false
        }
        if let cast = inner.as(AsExprSyntax.self) {
            return cast.questionOrExclamationMark?.tokenKind == .postfixQuestionMark
        }
        if let sequence = inner.as(SequenceExprSyntax.self) {
            return sequence.elements.contains { element in
                element.as(UnresolvedAsExprSyntax.self)?.questionOrExclamationMark?.tokenKind
                    == .postfixQuestionMark
            }
        }
        return false
    }

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
