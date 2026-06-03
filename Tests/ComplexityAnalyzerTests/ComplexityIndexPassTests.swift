import Foundation
import Testing
@testable import ComplexityAnalyzer
@testable import QualityGateCore

@Suite("ComplexityAnalyzer: Index-backed Pass 2 cross-module amplification")
struct ComplexityIndexPassTests {

    // MARK: - Helpers

    /// Creates a minimal FunctionComplexityRecord for testing.
    private func makeRecord(
        functionName: String = "doWork",
        moduleName: String = "ModuleA",
        filePath: String = "Sources/ModuleA/Worker.swift",
        startLine: Int = 1,
        cognitiveComplexity: Int = 10
    ) -> FunctionComplexityRecord {
        FunctionComplexityRecord(
            functionName: functionName,
            moduleName: moduleName,
            filePath: filePath,
            startLine: startLine,
            endLine: startLine + 10,
            cognitiveComplexity: cognitiveComplexity,
            cognitiveBreakdown: []
        )
    }

    /// Creates a CrossModuleCallEdge for testing.
    private func makeEdge(
        callerUSR: String = "ModuleA.doWork",
        calleeUSR: String = "s:7ModuleB9heavyFuncyyF",
        calleeName: String = "heavyFunc",
        calleeModule: String = "ModuleB",
        calleeCognitiveComplexity: Int = 20,
        insideLoop: Bool = false,
        line: Int = 5
    ) -> CrossModuleCallEdge {
        CrossModuleCallEdge(
            callerUSR: callerUSR,
            calleeUSR: calleeUSR,
            calleeName: calleeName,
            calleeModule: calleeModule,
            calleeCognitiveComplexity: calleeCognitiveComplexity,
            insideLoop: insideLoop,
            line: line
        )
    }

    // MARK: - Cross-module amplification adds callee cognitive complexity

    @Test("Amplification adds callee cognitive complexity to caller")
    func amplificationAddsCalleeComplexity() {
        let record = makeRecord(cognitiveComplexity: 10)
        let edge = makeEdge(calleeCognitiveComplexity: 20)

        let output = ComplexityIndexPass.amplify(
            records: [record],
            edges: [edge],
            cognitiveThreshold: 15,
            amplifiedThreshold: 25,
            moduleThresholds: [:],
            maxDepth: 1
        )

        #expect(output.records.count == 1)
        let amplified = output.records[0].amplifiedCognitiveComplexity
        #expect(amplified == 30) // 10 (local) + 20 (callee)
    }

    // MARK: - Amplification inside loop multiplies complexity

    @Test("Amplification inside loop triples callee cost")
    func amplificationInsideLoopMultiplies() {
        let record = makeRecord(cognitiveComplexity: 5)
        let edge = makeEdge(calleeCognitiveComplexity: 10, insideLoop: true)

        let output = ComplexityIndexPass.amplify(
            records: [record],
            edges: [edge],
            cognitiveThreshold: 15,
            amplifiedThreshold: 25,
            moduleThresholds: [:],
            maxDepth: 1
        )

        #expect(output.records.count == 1)
        let amplified = output.records[0].amplifiedCognitiveComplexity
        #expect(amplified == 35) // 5 (local) + 10 * 3 (loop amplification)
    }

    // MARK: - Emits diagnostic when amplified exceeds threshold but local does not

    @Test("Emits warning when amplified exceeds threshold but local does not")
    func emitsDiagnosticWhenAmplifiedExceedsThreshold() {
        let record = makeRecord(cognitiveComplexity: 10)
        let edge = makeEdge(calleeCognitiveComplexity: 25)

        let output = ComplexityIndexPass.amplify(
            records: [record],
            edges: [edge],
            cognitiveThreshold: 15,
            amplifiedThreshold: 30,
            moduleThresholds: [:],
            maxDepth: 1
        )

        #expect(output.diagnostics.count == 1)
        let diag = output.diagnostics[0]
        #expect(diag.severity == .warning)
        #expect(diag.ruleId == "complexity.cross-module-amplification")
        #expect(diag.message.contains("amplified cognitive complexity 35"))
        #expect(diag.message.contains("ModuleB.heavyFunc"))
    }

    // MARK: - No diagnostic when local already exceeds threshold

    @Test("No diagnostic when local complexity already exceeds threshold")
    func noDiagnosticWhenLocalExceedsThreshold() {
        let record = makeRecord(cognitiveComplexity: 20)
        let edge = makeEdge(calleeCognitiveComplexity: 25)

        let output = ComplexityIndexPass.amplify(
            records: [record],
            edges: [edge],
            cognitiveThreshold: 15,
            amplifiedThreshold: 30,
            moduleThresholds: [:],
            maxDepth: 1
        )

        // Local (20) > threshold (15), so no cross-module warning emitted.
        #expect(output.diagnostics.isEmpty)
    }

    // MARK: - No diagnostic when below threshold

    @Test("No diagnostic when amplified is below threshold")
    func noDiagnosticWhenBelowThreshold() {
        let record = makeRecord(cognitiveComplexity: 5)
        let edge = makeEdge(calleeCognitiveComplexity: 3)

        let output = ComplexityIndexPass.amplify(
            records: [record],
            edges: [edge],
            cognitiveThreshold: 15,
            amplifiedThreshold: 30,
            moduleThresholds: [:],
            maxDepth: 1
        )

        // Amplified (5 + 3 = 8) < threshold (30), so no warning.
        #expect(output.diagnostics.isEmpty)
    }

    // MARK: - Respects maxDepth limit

    @Test("Depth limit 0 cuts off all cross-module contribution")
    func depthZeroCutsOffCrossModule() {
        let edge = makeEdge(calleeCognitiveComplexity: 50)

        let amplified = ComplexityIndexPass.computeAmplifiedComplexity(
            localComplexity: 10,
            edges: [edge],
            complexityMap: [:],
            maxDepth: 0,
            visited: []
        )

        #expect(amplified == 10) // No cross-module contribution at depth 0
    }

    @Test("Depth 1 includes direct cross-module calls")
    func depthOneIncludesDirectCalls() {
        let edge = makeEdge(calleeCognitiveComplexity: 20)

        let amplified = ComplexityIndexPass.computeAmplifiedComplexity(
            localComplexity: 10,
            edges: [edge],
            complexityMap: [:],
            maxDepth: 1,
            visited: []
        )

        #expect(amplified == 30) // 10 + 20
    }

    // MARK: - Cyclic call graph terminates

    @Test("Cyclic call graph terminates via visited set")
    func cyclicCallGraphTerminates() {
        // Simulate: A calls B, B calls A (but B's USR is already visited)
        let edgeAtoB = makeEdge(
            callerUSR: "ModuleA.doWork",
            calleeUSR: "ModuleB.helper",
            calleeCognitiveComplexity: 15
        )

        // When "ModuleB.helper" is already in the visited set, it should be skipped
        let amplified = ComplexityIndexPass.computeAmplifiedComplexity(
            localComplexity: 10,
            edges: [edgeAtoB],
            complexityMap: [:],
            maxDepth: 1,
            visited: ["ModuleB.helper"] // Already visited
        )

        #expect(amplified == 10) // Callee skipped due to cycle
    }

    // MARK: - Graceful degradation

    @Test("Emits note diagnostic when index store is unavailable")
    func gracefulDegradationWhenNoIndex() {
        let diag = ComplexityIndexPass.unavailableNote()
        #expect(diag.severity == .note)
        #expect(diag.ruleId == "complexity.index-pass.skipped")
        #expect(diag.message.contains("Complexity Pass 2 skipped"))
    }

    // MARK: - Pass 1 results unchanged in degradation scenarios

    @Test("Pass 1 records unchanged when no edges exist")
    func pass1ResultsUnchangedWithNoEdges() {
        let records = [
            makeRecord(functionName: "foo", cognitiveComplexity: 12),
            makeRecord(functionName: "bar", cognitiveComplexity: 8),
        ]

        let output = ComplexityIndexPass.amplify(
            records: records,
            edges: [],
            cognitiveThreshold: 15,
            amplifiedThreshold: 30,
            moduleThresholds: [:],
            maxDepth: 1
        )

        #expect(output.records.count == 2)
        #expect(output.records[0].cognitiveComplexity == 12)
        #expect(output.records[0].amplifiedCognitiveComplexity == nil)
        #expect(output.records[1].cognitiveComplexity == 8)
        #expect(output.records[1].amplifiedCognitiveComplexity == nil)
        #expect(output.diagnostics.isEmpty)
    }

    // MARK: - Configuration tests

    @Test("Config defaults useIndexStore to true")
    func configDefaultsUseIndexStore() {
        let config = ComplexityAnalyzerConfig.default
        #expect(config.useIndexStore == true)
    }

    @Test("Config defaults crossModuleAmplification to true")
    func configDefaultsCrossModuleAmplification() {
        let config = ComplexityAnalyzerConfig.default
        #expect(config.crossModuleAmplification == true)
    }

    @Test("Config defaults crossModuleMaxDepth to 1")
    func configDefaultsCrossModuleMaxDepth() {
        let config = ComplexityAnalyzerConfig.default
        #expect(config.crossModuleMaxDepth == 1)
    }

    @Test("Config defaults amplifiedCognitiveThreshold to 30")
    func configDefaultsAmplifiedCognitiveThreshold() {
        let config = ComplexityAnalyzerConfig.default
        #expect(config.amplifiedCognitiveThreshold == 30)
    }

    @Test("Config decodes new fields from YAML")
    func configDecodesNewFieldsFromYAML() throws {
        let yaml = """
        complexity:
          useIndexStore: false
          crossModuleAmplification: false
          crossModuleMaxDepth: 3
          amplifiedCognitiveThreshold: 50
        """
        let config = try Configuration.from(yaml: yaml)
        #expect(config.complexity.useIndexStore == false)
        #expect(config.complexity.crossModuleAmplification == false)
        #expect(config.complexity.crossModuleMaxDepth == 3)
        #expect(config.complexity.amplifiedCognitiveThreshold == 50)
    }

    @Test("Config decodes with defaults when new fields omitted")
    func configDecodesWithDefaultsWhenFieldsOmitted() throws {
        let yaml = """
        complexity:
          cognitiveThreshold: 20
        """
        let config = try Configuration.from(yaml: yaml)
        #expect(config.complexity.cognitiveThreshold == 20)
        #expect(config.complexity.useIndexStore == true)
        #expect(config.complexity.crossModuleAmplification == true)
        #expect(config.complexity.crossModuleMaxDepth == 1)
        #expect(config.complexity.amplifiedCognitiveThreshold == 30)
    }

    // MARK: - run(inputs:) entry point

    @Test("run(inputs:) delegates to amplify correctly")
    func runDelegatesToAmplify() {
        let record = makeRecord(cognitiveComplexity: 8)
        let edge = makeEdge(calleeCognitiveComplexity: 25)

        let inputs = ComplexityIndexPass.Inputs(
            records: [record],
            edges: [edge],
            crossModuleMaxDepth: 1,
            cognitiveThreshold: 15,
            amplifiedCognitiveThreshold: 30,
            moduleThresholds: [:]
        )

        let output = ComplexityIndexPass.run(inputs: inputs)

        #expect(output.records.count == 1)
        #expect(output.records[0].amplifiedCognitiveComplexity == 33) // 8 + 25
        #expect(output.diagnostics.count == 1)
        #expect(output.diagnostics[0].ruleId == "complexity.cross-module-amplification")
    }

    // MARK: - Module threshold overrides

    @Test("Per-module threshold override suppresses diagnostic when local exceeds module threshold")
    func moduleThresholdOverrideSuppressesDiagnostic() {
        let record = makeRecord(
            functionName: "process",
            moduleName: "Parser",
            cognitiveComplexity: 12
        )
        let edge = CrossModuleCallEdge(
            callerUSR: "Parser.process",
            calleeUSR: "s:7ModuleB4helpyyF",
            calleeName: "help",
            calleeModule: "ModuleB",
            calleeCognitiveComplexity: 25,
            insideLoop: false,
            line: 5
        )

        let output = ComplexityIndexPass.amplify(
            records: [record],
            edges: [edge],
            cognitiveThreshold: 15,
            amplifiedThreshold: 30,
            moduleThresholds: ["Parser": 10], // Parser threshold is 10, local 12 > 10
            maxDepth: 1
        )

        // Local (12) > module threshold (10), so no cross-module warning emitted.
        #expect(output.diagnostics.isEmpty)
    }

    // MARK: - CrossModuleCallEdge Codable

    @Test("CrossModuleCallEdge is Codable round-trip")
    func crossModuleCallEdgeCodable() throws {
        let edge = makeEdge()
        let encoder = JSONEncoder()
        let data = try encoder.encode(edge)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CrossModuleCallEdge.self, from: data)
        #expect(decoded == edge)
    }

    // MARK: - ComplexityBasis cross-module case

    @Test("CrossModuleCognitiveAmplification basis has correct description")
    func crossModuleBasisDescription() {
        let basis = ComplexityBasis.crossModuleCognitiveAmplification(
            callee: "heavyFunc",
            module: "ModuleB",
            calleeCost: 20
        )
        #expect(basis.description == "cross-module heavyFunc in ModuleB (complexity 20)")
    }

    // MARK: - Multiple edges from same caller

    @Test("Multiple cross-module edges accumulate complexity")
    func multipleEdgesAccumulate() {
        let edge1 = makeEdge(
            calleeUSR: "s:7ModuleB4funcyyF",
            calleeName: "func1",
            calleeCognitiveComplexity: 10
        )
        let edge2 = CrossModuleCallEdge(
            callerUSR: "ModuleA.doWork",
            calleeUSR: "s:7ModuleC4funcyyF",
            calleeName: "func2",
            calleeModule: "ModuleC",
            calleeCognitiveComplexity: 8,
            insideLoop: false,
            line: 7
        )

        let amplified = ComplexityIndexPass.computeAmplifiedComplexity(
            localComplexity: 5,
            edges: [edge1, edge2],
            complexityMap: [:],
            maxDepth: 1,
            visited: []
        )

        #expect(amplified == 23) // 5 + 10 + 8
    }
}
