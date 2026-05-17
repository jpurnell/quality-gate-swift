import SwiftSyntax
import SwiftParser

/// Amplifies per-function complexity estimates using call-graph analysis.
///
/// When function A calls function B inside a loop, A's effective complexity
/// is at least loop_depth * B's complexity. This pass re-evaluates estimates
/// after initial per-function analysis.
struct CallGraphAmplifier {

    /// Analyzes source with call-graph amplification applied.
    static func analyze(source: String, moduleName: String, maxDepth: Int = 1, userCosts: [String: String] = [:]) -> [FunctionComplexityRecord] {
        let analyzer = ComplexityAnalyzer()
        var records = analyzer.analyzeSource(source, moduleName: moduleName, userCosts: userCosts)
        let graph = CallGraphBuilder.build(source: source, moduleName: moduleName)

        let costMap = buildCostMap(from: records, graph: graph, maxDepth: maxDepth)

        for i in records.indices {
            let record = records[i]
            let amplifiedCost = costMap[record.functionName] ?? record.estimatedTimeComplexity
            if orderOf(amplifiedCost) > orderOf(record.estimatedTimeComplexity) {
                let newBasis = buildAmplifiedBasis(
                    for: record.functionName,
                    graph: graph,
                    costMap: costMap,
                    originalBasis: record.complexityBasis
                )
                records[i] = FunctionComplexityRecord(
                    functionName: record.functionName,
                    moduleName: record.moduleName,
                    filePath: record.filePath,
                    startLine: record.startLine,
                    endLine: record.endLine,
                    cognitiveComplexity: record.cognitiveComplexity,
                    cognitiveBreakdown: record.cognitiveBreakdown,
                    estimatedTimeComplexity: amplifiedCost,
                    complexityBasis: newBasis,
                    confidence: record.confidence,
                    detectedPatterns: record.detectedPatterns
                )
            }
        }

        return records
    }

    /// Iteratively computes effective complexity for each function up to maxDepth.
    private static func buildCostMap(
        from records: [FunctionComplexityRecord],
        graph: CallGraph,
        maxDepth: Int
    ) -> [String: String] {
        var baseCosts: [String: String] = [:]
        for record in records {
            baseCosts[record.functionName] = record.estimatedTimeComplexity
        }

        var effectiveCosts = baseCosts

        for _ in 0..<maxDepth {
            var nextCosts = effectiveCosts
            var updated = false

            for record in records {
                let edges = graph.callees(of: record.functionName)
                var best = baseCosts[record.functionName] ?? "O(1)"

                for edge in edges where edge.insideLoop {
                    guard let calleeCost = effectiveCosts[edge.callee] else { continue }
                    let amplified = multiplyByN(calleeCost)
                    if orderOf(amplified) > orderOf(best) {
                        best = amplified
                    }
                }

                for edge in edges where !edge.insideLoop {
                    guard let calleeCost = effectiveCosts[edge.callee] else { continue }
                    if orderOf(calleeCost) > orderOf(best) {
                        best = calleeCost
                    }
                }

                if orderOf(best) > orderOf(nextCosts[record.functionName] ?? "O(1)") {
                    nextCosts[record.functionName] = best
                    updated = true
                }
            }

            effectiveCosts = nextCosts
            if !updated { break }
        }

        return effectiveCosts
    }

    private static func multiplyByN(_ calleeCost: String) -> String {
        let order = orderOf(calleeCost)
        return complexityForOrder(order + 2)
    }

    private static func buildAmplifiedBasis(
        for function: String,
        graph: CallGraph,
        costMap: [String: String],
        originalBasis: [ComplexityBasis]
    ) -> [ComplexityBasis] {
        var basis = originalBasis
        let edges = graph.callees(of: function)
        for edge in edges where edge.insideLoop {
            if let calleeCost = costMap[edge.callee], orderOf(calleeCost) > 0 {
                basis.append(.callGraphAmplification(callee: edge.callee, calleeCost: calleeCost))
            }
        }
        return basis
    }

    static func orderOf(_ complexity: String) -> Int {
        switch complexity {
        case "O(1)": return 0
        case "O(log n)": return 1
        case "O(n)": return 2
        case "O(n log n)": return 3
        case "O(n²)": return 4
        case "O(n² log n)": return 5
        case "O(n³)": return 6
        default:
            if complexity.contains("n^") { return 7 }
            return 2
        }
    }

    private static func complexityForOrder(_ order: Int) -> String {
        switch order {
        case 0: return "O(1)"
        case 1: return "O(log n)"
        case 2: return "O(n)"
        case 3: return "O(n log n)"
        case 4: return "O(n²)"
        case 5: return "O(n² log n)"
        case 6: return "O(n³)"
        default: return "O(n^\(order - 2))"
        }
    }
}
