import Foundation

/// A single increment contributing to a function's cognitive complexity score.
public struct CognitiveIncrement: Sendable, Codable, Equatable {
    /// The syntax node type (e.g. "if", "for", "guard…else", "&&").
    public let node: String
    /// The source line where this increment occurs.
    public let line: Int
    /// Base increment for the flow break (+1).
    public let baseIncrement: Int
    /// Additional increment for nesting depth.
    public let nestingIncrement: Int

    /// Total contribution of this increment.
    public var total: Int { baseIncrement + nestingIncrement }

    /// Creates a cognitive increment record.
    public init(node: String, line: Int, baseIncrement: Int, nestingIncrement: Int) {
        self.node = node
        self.line = line
        self.baseIncrement = baseIncrement
        self.nestingIncrement = nestingIncrement
    }
}

/// Confidence level for a static Big-O estimation.
public enum EstimationConfidence: String, Sendable, Codable, Equatable, CaseIterable {
    case high
    case medium
    case low

    /// Whether the estimate should be treated with caution.
    public var isUncertain: Bool {
        self == .low || self == .medium
    }
}

/// Complexity record for a single function.
public struct FunctionComplexityRecord: Sendable, Codable, Equatable {
    /// The function's declared name.
    public let functionName: String
    /// The module this function belongs to.
    public let moduleName: String
    /// Absolute path to the source file.
    public let filePath: String
    /// Start line of the function declaration.
    public let startLine: Int
    /// End line of the function body.
    public let endLine: Int

    /// Deterministic cognitive complexity score.
    public let cognitiveComplexity: Int
    /// Breakdown of each increment contributing to the score.
    public let cognitiveBreakdown: [CognitiveIncrement]

    /// Estimated Big-O time complexity (e.g. "O(1)", "O(n)", "O(n²)").
    public let estimatedTimeComplexity: String
    /// What patterns drove the Big-O estimate.
    public let complexityBasis: [ComplexityBasis]
    /// Confidence in the Big-O estimate.
    public let confidence: EstimationConfidence
    /// Anti-patterns detected in this function.
    public let detectedPatterns: [ComplexityPattern]

    /// Amplified cognitive complexity accounting for cross-module call costs.
    /// nil when Pass 2 (IndexStoreDB) has not run or no amplification applies.
    public let amplifiedCognitiveComplexity: Int?

    /// Cross-module callees resolved via IndexStoreDB.
    public let crossModuleCallees: [CrossModuleCallEdge]

    /// Creates a function complexity record.
    public init(
        functionName: String,
        moduleName: String,
        filePath: String,
        startLine: Int,
        endLine: Int,
        cognitiveComplexity: Int,
        cognitiveBreakdown: [CognitiveIncrement],
        estimatedTimeComplexity: String = "O(1)",
        complexityBasis: [ComplexityBasis] = [],
        confidence: EstimationConfidence = .high,
        detectedPatterns: [ComplexityPattern] = [],
        amplifiedCognitiveComplexity: Int? = nil,
        crossModuleCallees: [CrossModuleCallEdge] = []
    ) {
        self.functionName = functionName
        self.moduleName = moduleName
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.cognitiveComplexity = cognitiveComplexity
        self.cognitiveBreakdown = cognitiveBreakdown
        self.estimatedTimeComplexity = estimatedTimeComplexity
        self.complexityBasis = complexityBasis
        self.confidence = confidence
        self.detectedPatterns = detectedPatterns
        self.amplifiedCognitiveComplexity = amplifiedCognitiveComplexity
        self.crossModuleCallees = crossModuleCallees
    }
}

/// A detected algorithmic anti-pattern.
public enum ComplexityPattern: Sendable, Codable, Equatable {
    /// Linear search (`contains`, `first(where:)`) inside a filter/map/loop over a collection.
    case containsInFilter(collection: String, line: Int)
    /// Nested loop iterating the same or related collection.
    case nestedLoopSameCollection(collection: String, outerLine: Int, innerLine: Int)
    /// Multiple linear searches on the same collection that could use a dictionary.
    case repeatedLinearSearch(collection: String, count: Int)
    /// Sorting inside a loop body.
    case sortInLoop(line: Int)
    /// String concatenation with `+=` inside a loop.
    case quadraticStringConcat(line: Int)
}

/// What drove a Big-O estimate.
public enum ComplexityBasis: Sendable, Codable, Equatable {
    /// Loop nesting depth (e.g., depth 2 → O(n²)).
    case loopNesting(depth: Int)
    /// Known stdlib operation cost.
    case stdlibOperation(name: String, cost: String)
    /// Recursion pattern classification.
    case recursion(type: RecursionClassification)
    /// Cross-function amplification from call graph analysis.
    case callGraphAmplification(callee: String, calleeCost: String)
    /// Cross-module cognitive complexity amplification from IndexStoreDB analysis.
    case crossModuleCognitiveAmplification(callee: String, module: String, calleeCost: Int)

    /// Human-readable description of this basis element.
    public var description: String {
        switch self {
        case .loopNesting(let depth): return "loop nesting depth \(depth)"
        case .stdlibOperation(let name, let cost): return "\(name) (\(cost))"
        case .recursion(let type): return "recursion: \(type.rawValue)"
        case .callGraphAmplification(let callee, let cost): return "calls \(callee) (\(cost))"
        case .crossModuleCognitiveAmplification(let callee, let module, let cost): return "cross-module \(callee) in \(module) (complexity \(cost))"
        }
    }
}

/// Classification of recursive call patterns.
public enum RecursionClassification: String, Sendable, Codable, Equatable, CaseIterable {
    /// f(n-1) — O(n)
    case linear
    /// f(n/2) + f(n/2) — O(n log n)
    case divideConquer
    /// f(n-1) + f(n-1) — O(2^n)
    case branching
    /// Tail-recursive, optimizable
    case tail

    /// Estimated Big-O for this recursion pattern.
    public var estimatedComplexity: String {
        switch self {
        case .linear: return "O(n)"
        case .divideConquer: return "O(n log n)"
        case .branching: return "O(2^n)"
        case .tail: return "O(n)"
        }
    }
}

/// A directed edge in the cross-module call graph, resolved by USR.
public struct CrossModuleCallEdge: Sendable, Codable, Equatable {
    /// USR of the calling function.
    public let callerUSR: String
    /// USR of the called function.
    public let calleeUSR: String
    /// Human-readable name of the callee.
    public let calleeName: String
    /// Module containing the callee.
    public let calleeModule: String
    /// Cognitive complexity of the callee.
    public let calleeCognitiveComplexity: Int
    /// Whether the call occurs inside a loop in the caller.
    public let insideLoop: Bool
    /// Source line of the call site.
    public let line: Int

    /// Creates a cross-module call edge.
    public init(
        callerUSR: String,
        calleeUSR: String,
        calleeName: String,
        calleeModule: String,
        calleeCognitiveComplexity: Int,
        insideLoop: Bool,
        line: Int
    ) {
        self.callerUSR = callerUSR
        self.calleeUSR = calleeUSR
        self.calleeName = calleeName
        self.calleeModule = calleeModule
        self.calleeCognitiveComplexity = calleeCognitiveComplexity
        self.insideLoop = insideLoop
        self.line = line
    }
}

/// A directed edge in a function call graph.
public struct CallEdge: Sendable, Codable, Equatable {
    /// Name of the calling function.
    public let caller: String
    /// Name of the called function.
    public let callee: String
    /// Whether the call occurs inside a loop in the caller.
    public let insideLoop: Bool
    /// Source line of the call site.
    public let line: Int

    /// Creates a call edge.
    public init(caller: String, callee: String, insideLoop: Bool, line: Int) {
        self.caller = caller
        self.callee = callee
        self.insideLoop = insideLoop
        self.line = line
    }
}

/// Intra-module call graph built from static analysis.
public struct CallGraph: Sendable, Codable, Equatable {
    /// All directed edges (caller → callee).
    public let edges: [CallEdge]
    /// Set of function names defined in this module.
    public let definedFunctions: Set<String>

    /// Creates a call graph.
    public init(edges: [CallEdge], definedFunctions: Set<String>) {
        self.edges = edges
        self.definedFunctions = definedFunctions
    }

    /// Returns all callees for a given function.
    public func callees(of function: String) -> [CallEdge] {
        edges.filter { $0.caller == function }
    }

    /// Returns all callers of a given function.
    public func callers(of function: String) -> [CallEdge] {
        edges.filter { $0.callee == function }
    }
}

/// Aggregate complexity summary for a module.
public struct ModuleComplexitySummary: Sendable, Codable, Equatable {
    /// The module's name.
    public let moduleName: String
    /// All function records in this module.
    public let functions: [FunctionComplexityRecord]
    /// Median cognitive complexity across all functions.
    public let medianCognitive: Int
    /// Maximum cognitive complexity in the module.
    public let maxCognitive: Int
    /// Count of functions exceeding the configured threshold.
    public let functionsAboveThreshold: Int

    /// Creates a module complexity summary.
    public init(
        moduleName: String,
        functions: [FunctionComplexityRecord],
        medianCognitive: Int,
        maxCognitive: Int,
        functionsAboveThreshold: Int
    ) {
        self.moduleName = moduleName
        self.functions = functions
        self.medianCognitive = medianCognitive
        self.maxCognitive = maxCognitive
        self.functionsAboveThreshold = functionsAboveThreshold
    }
}
