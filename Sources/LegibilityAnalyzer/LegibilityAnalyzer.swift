import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// Advisory whole-codebase legibility analyzer.
///
/// Reports on the navigability of *live* code at module scale — module
/// centrality/orientation, dependency cycles, and (via the IndexStore pass)
/// over-exposed public surface — and emits a reading-order / module-map artifact.
/// It is advisory-only: every diagnostic is a `.note` and the status is never
/// `.failed`. See `PROPOSALS/LegibilityAnalyzer.md`.
///
/// This first cut runs on the *declared* `Package.swift` dependency graph, which
/// drives the central-unoriented and module-cycle rules and the reading-order
/// artifact. The over-public rule requires the semantic (IndexStore) pass and is
/// wired separately.
public struct LegibilityAnalyzer: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "LegibilityAnalyzer")

    /// The checker identifier.
    public let id = "legibility"
    /// The human-readable name.
    public let name = "Legibility Analyzer"
    /// Read-only over parsed sources; safe to run concurrently.
    public var isParallelSafe: Bool { true }

    /// Creates a legibility analyzer.
    public init() {}

    /// The pure result of analysis: advisory notes, compliance records, and the map.
    public struct AnalysisResult: Sendable {
        /// Advisory `.note` diagnostics.
        public let diagnostics: [Diagnostic]
        /// Acknowledged over-public exceptions, surfaced not dropped.
        public let compliance: [ComplianceRecord]
        /// The reading-order / module-map artifact.
        public let map: LegibilityMap
    }

    /// Runs all rules and builds the map over already-resolved facts.
    ///
    /// Pure and deterministic — no file or index I/O — so it is fully unit-testable.
    public static func analyze(
        graph: ModuleGraph,
        orientation: [ModuleOrientation],
        overPublic: [OverPublicOccurrence],
        overPublicByModule: [String: Int],
        config: LegibilityAnalyzerConfig
    ) -> AnalysisResult {
        var diagnostics: [Diagnostic] = []
        diagnostics.append(contentsOf: LegibilityRules.centralUnoriented(graph: graph, orientation: orientation, config: config))
        diagnostics.append(contentsOf: LegibilityRules.moduleCycles(graph: graph, config: config))

        let overFindings = LegibilityRules.overPublicSymbols(overPublic, config: config)
        diagnostics.append(contentsOf: overFindings.diagnostics)

        let map = LegibilityMapBuilder.build(
            graph: graph,
            orientation: orientation,
            overPublicByModule: overPublicByModule
        )
        return AnalysisResult(diagnostics: diagnostics, compliance: overFindings.compliance, map: map)
    }

    /// Runs the analyzer against the current project.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let config = configuration.legibility
        let cwd = FileManager.default.currentDirectoryPath

        let graph = loadDeclaredGraph(cwd: cwd, config: config)
        let orientation = discoverOrientation(cwd: cwd, modules: graph.modules)

        // Over-public analysis requires the semantic (IndexStore) pass; the
        // declared-graph run supplies no over-public facts.
        let result = Self.analyze(
            graph: graph,
            orientation: orientation,
            overPublic: [],
            overPublicByModule: [:],
            config: config
        )

        if config.emitReadingOrderArtifact {
            writeArtifact(result.map, cwd: cwd, config: config)
        }

        // Advisory-only: always `.passed`. The findings are `.note` diagnostics
        // that surface to the user but must never gate a commit — matching the
        // ComplexityAnalyzer precedent.
        let duration = ContinuousClock.now - startTime
        return CheckResult(
            checkerId: id,
            status: .passed,
            diagnostics: result.diagnostics,
            complianceRecords: result.compliance,
            duration: duration
        )
    }

    // MARK: - I/O helpers

    private func loadDeclaredGraph(cwd: String, config: LegibilityAnalyzerConfig) -> ModuleGraph {
        let packagePath = (cwd as NSString).appendingPathComponent("Package.swift")
        // silent: absent/unreadable manifest simply yields an empty graph (advisory checker never fails).
        guard let source = try? String(contentsOfFile: packagePath, encoding: .utf8) else {
            return ModuleGraph(edges: [:])
        }
        let graph = PackageGraphLoader.declaredGraph(packageSource: source, includingTestTargets: false)
        guard !config.exemptModules.isEmpty else { return graph }

        // Drop exempt modules from the graph entirely.
        var edges: [String: Set<String>] = [:]
        for (from, tos) in graph.edges where !config.exemptModules.contains(from) {
            let kept = tos.subtracting(config.exemptModules)
            if !kept.isEmpty { edges[from] = kept }
        }
        return ModuleGraph(edges: edges)
    }

    private func discoverOrientation(cwd: String, modules: Set<String>) -> [ModuleOrientation] {
        let sourcesPath = (cwd as NSString).appendingPathComponent("Sources")
        return modules.sorted().map { module in
            let moduleDir = (sourcesPath as NSString).appendingPathComponent(module)
            return ModuleOrientation(moduleName: module, hasOrientationDoc: hasDocCCatalog(moduleDir: moduleDir))
        }
    }

    private func hasDocCCatalog(moduleDir: String) -> Bool {
        // silent: a module directory we cannot list is treated as having no catalog.
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: moduleDir) else {
            return false
        }
        return entries.contains { $0.hasSuffix(".docc") }
    }

    private func writeArtifact(_ map: LegibilityMap, cwd: String, config: LegibilityAnalyzerConfig) {
        let basePath = config.artifactPath ?? (cwd as NSString).appendingPathComponent(".build/legibility")
        let fileManager = FileManager.default
        do {
            // SAFETY: CLI tool writes its advisory artifact under the project's .build directory.
            try fileManager.createDirectory(atPath: basePath, withIntermediateDirectories: true)
            let jsonPath = (basePath as NSString).appendingPathComponent("legibility-map.json")
            let markdownPath = (basePath as NSString).appendingPathComponent("READING_ORDER.md")
            try LegibilityMapRenderer.json(map).write(toFile: jsonPath, atomically: true, encoding: .utf8)
            try LegibilityMapRenderer.markdown(map).write(toFile: markdownPath, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.warning("Failed to write legibility artifact: \(error.localizedDescription, privacy: .public)")
        }
    }
}
