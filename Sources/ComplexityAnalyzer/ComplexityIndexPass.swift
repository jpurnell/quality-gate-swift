import Foundation
import QualityGateCore

/// Cross-module cognitive complexity amplification backed by IndexStoreDB (Pass 2).
///
/// When IndexStoreDB is available, this pass resolves function calls that cross
/// module boundaries and computes an amplified cognitive complexity score that
/// accounts for the callee's cognitive cost. Functions whose amplified score
/// exceeds the configured threshold — but whose local score does not — receive
/// a `complexity.cross-module-amplification` warning.
///
/// ## Pure analysis design
/// The analysis logic is split into pure static functions (``amplify(records:edges:cognitiveThreshold:amplifiedThreshold:moduleThresholds:)``,
/// ``computeAmplifiedComplexity(localComplexity:edges:complexityMap:maxDepth:visited:)``)
/// so that unit tests can exercise them without a live IndexStoreDB session.
///
/// ## Graceful degradation
/// When the index store is unavailable, the pass emits a single `.note`
/// diagnostic and returns — it never fails the quality gate.
public enum ComplexityIndexPass: Sendable {

    // MARK: - Data types

    /// Inputs required to run the cross-module complexity pass.
    public struct Inputs: Sendable {
        /// Pass 1 function complexity records.
        public let records: [FunctionComplexityRecord]
        /// Cross-module call edges resolved from the index.
        public let edges: [CrossModuleCallEdge]
        /// Maximum transitive depth for cross-module resolution.
        public let crossModuleMaxDepth: Int
        /// Base cognitive complexity threshold (Pass 1).
        public let cognitiveThreshold: Int
        /// Amplified cognitive complexity threshold for cross-module warnings.
        public let amplifiedCognitiveThreshold: Int
        /// Per-module threshold overrides.
        public let moduleThresholds: [String: Int]

        /// Creates inputs for the complexity index pass.
        public init(
            records: [FunctionComplexityRecord],
            edges: [CrossModuleCallEdge],
            crossModuleMaxDepth: Int,
            cognitiveThreshold: Int,
            amplifiedCognitiveThreshold: Int,
            moduleThresholds: [String: Int]
        ) {
            self.records = records
            self.edges = edges
            self.crossModuleMaxDepth = crossModuleMaxDepth
            self.cognitiveThreshold = cognitiveThreshold
            self.amplifiedCognitiveThreshold = amplifiedCognitiveThreshold
            self.moduleThresholds = moduleThresholds
        }
    }

    /// Output from the cross-module complexity pass.
    public struct Output: Sendable {
        /// Updated function records with amplified complexity where applicable.
        public let records: [FunctionComplexityRecord]
        /// Diagnostics emitted by the pass.
        public let diagnostics: [Diagnostic]

        /// Creates an output from the complexity index pass.
        public init(records: [FunctionComplexityRecord], diagnostics: [Diagnostic]) {
            self.records = records
            self.diagnostics = diagnostics
        }
    }

    // MARK: - Entry point

    /// Runs cross-module complexity amplification using pre-resolved edges.
    ///
    /// This is the main orchestrator. It takes Pass 1 records and cross-module
    /// edges (resolved by the caller via IndexStoreDB) and produces updated
    /// records with amplified complexity scores and any resulting diagnostics.
    ///
    /// - Parameter inputs: The inputs for the pass.
    /// - Returns: Updated records and diagnostics.
    public static func run(inputs: Inputs) -> Output {
        return amplify(
            records: inputs.records,
            edges: inputs.edges,
            cognitiveThreshold: inputs.cognitiveThreshold,
            amplifiedThreshold: inputs.amplifiedCognitiveThreshold,
            moduleThresholds: inputs.moduleThresholds,
            maxDepth: inputs.crossModuleMaxDepth
        )
    }

    // MARK: - Pure analysis

    /// Computes amplified cognitive complexity for each function and emits diagnostics.
    ///
    /// For each function record, sums the callee cognitive complexities from
    /// cross-module edges. Calls inside loops multiply the callee cost by a
    /// loop amplification factor. When the amplified score exceeds
    /// `amplifiedThreshold` but the local score does not exceed the base
    /// threshold, a `complexity.cross-module-amplification` warning is emitted.
    ///
    /// - Parameters:
    ///   - records: Pass 1 function complexity records.
    ///   - edges: Cross-module call edges.
    ///   - cognitiveThreshold: Local cognitive threshold from configuration.
    ///   - amplifiedThreshold: Cross-module amplified threshold.
    ///   - moduleThresholds: Per-module overrides for the local threshold.
    ///   - maxDepth: Maximum transitive depth for resolution.
    /// - Returns: Updated records and diagnostics.
    public static func amplify(
        records: [FunctionComplexityRecord],
        edges: [CrossModuleCallEdge],
        cognitiveThreshold: Int,
        amplifiedThreshold: Int,
        moduleThresholds: [String: Int],
        maxDepth: Int
    ) -> Output {
        // Build a lookup from callerUSR to edges.
        var edgesByCallerUSR: [String: [CrossModuleCallEdge]] = [:]
        for edge in edges {
            edgesByCallerUSR[edge.callerUSR, default: []].append(edge)
        }

        // Build a complexity lookup for callees by USR.
        var complexityByUSR: [String: Int] = [:]
        for edge in edges {
            complexityByUSR[edge.calleeUSR] = edge.calleeCognitiveComplexity
        }

        var updatedRecords: [FunctionComplexityRecord] = []
        var diagnostics: [Diagnostic] = []

        for record in records {
            // Collect edges for this specific record using callerUSR.
            // The caller is responsible for keying callerUSR consistently
            // as "moduleName.functionName" when real USRs are unavailable.
            let callerKey = "\(record.moduleName).\(record.functionName)"
            let recordEdges = edgesByCallerUSR[callerKey] ?? []

            guard !recordEdges.isEmpty else {
                updatedRecords.append(record)
                continue
            }

            let amplifiedComplexity = computeAmplifiedComplexity(
                localComplexity: record.cognitiveComplexity,
                edges: recordEdges,
                complexityMap: complexityByUSR,
                maxDepth: maxDepth,
                visited: []
            )

            var newBasis = record.complexityBasis
            for edge in recordEdges {
                newBasis.append(.crossModuleCognitiveAmplification(
                    callee: edge.calleeName,
                    module: edge.calleeModule,
                    calleeCost: edge.calleeCognitiveComplexity
                ))
            }

            let updatedRecord = FunctionComplexityRecord(
                functionName: record.functionName,
                moduleName: record.moduleName,
                filePath: record.filePath,
                startLine: record.startLine,
                endLine: record.endLine,
                cognitiveComplexity: record.cognitiveComplexity,
                cognitiveBreakdown: record.cognitiveBreakdown,
                estimatedTimeComplexity: record.estimatedTimeComplexity,
                complexityBasis: newBasis,
                confidence: record.confidence,
                detectedPatterns: record.detectedPatterns,
                amplifiedCognitiveComplexity: amplifiedComplexity,
                crossModuleCallees: recordEdges
            )
            updatedRecords.append(updatedRecord)

            // Emit diagnostic if amplified exceeds threshold but local does not.
            let localThreshold = moduleThresholds[record.moduleName] ?? cognitiveThreshold
            let localExceedsThreshold = record.cognitiveComplexity > localThreshold
            let amplifiedExceedsThreshold = amplifiedComplexity > amplifiedThreshold

            if amplifiedExceedsThreshold && !localExceedsThreshold {
                let calleeDetails = recordEdges.map { edge in
                    "\(edge.calleeModule).\(edge.calleeName) (cognitive: \(edge.calleeCognitiveComplexity))"
                }.joined(separator: ", ")

                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "\(record.functionName) has amplified cognitive complexity \(amplifiedComplexity) (threshold: \(amplifiedThreshold)) due to cross-module calls: \(calleeDetails)",
                    filePath: record.filePath,
                    lineNumber: record.startLine,
                    ruleId: "complexity.cross-module-amplification",
                    suggestedFix: "Consider extracting cross-module call chains into smaller functions, or raising the amplified threshold if the complexity is justified."
                ))
            }
        }

        return Output(records: updatedRecords, diagnostics: diagnostics)
    }

    /// Computes the amplified cognitive complexity for a single function.
    ///
    /// Adds the callee cognitive complexity for each cross-module edge.
    /// Calls inside loops apply a 3x multiplier to the callee cost to
    /// reflect the cognitive burden of understanding loop-embedded
    /// cross-module behavior.
    ///
    /// - Parameters:
    ///   - localComplexity: The function's own cognitive complexity.
    ///   - edges: Cross-module call edges from this function.
    ///   - complexityMap: USR-keyed lookup of callee complexities.
    ///   - maxDepth: Maximum transitive depth (0 = no cross-module contribution).
    ///   - visited: Set of already-visited USRs to prevent cycles.
    /// - Returns: The amplified cognitive complexity score.
    public static func computeAmplifiedComplexity(
        localComplexity: Int,
        edges: [CrossModuleCallEdge],
        complexityMap: [String: Int],
        maxDepth: Int,
        visited: Set<String>
    ) -> Int {
        guard maxDepth > 0 else { return localComplexity }

        var total = localComplexity
        for edge in edges {
            guard !visited.contains(edge.calleeUSR) else { continue }

            let calleeCost = complexityMap[edge.calleeUSR] ?? edge.calleeCognitiveComplexity
            if edge.insideLoop {
                // Loop amplification: callee cost is tripled to reflect
                // the cognitive burden of understanding repeated cross-module calls.
                total += calleeCost * 3
            } else {
                total += calleeCost
            }
        }

        return total
    }

    // MARK: - Graceful degradation

    /// Returns a note diagnostic indicating that the complexity index pass was skipped.
    ///
    /// Used when the index store is unavailable, misconfigured, or the
    /// `useIndexStore` configuration option is disabled. This ensures the quality
    /// gate never fails solely because of a missing index.
    ///
    /// - Returns: A `.note` severity diagnostic.
    public static func unavailableNote() -> Diagnostic {
        Diagnostic(
            severity: .note,
            message: "Complexity Pass 2 skipped: index store unavailable. Build the project to enable cross-module complexity analysis.",
            ruleId: "complexity.index-pass.skipped"
        )
    }
}
