import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import IndexStoreInfra

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
    struct AnalysisResult: Sendable {
        /// Advisory `.note` diagnostics.
        let diagnostics: [Diagnostic]
        /// Acknowledged over-public exceptions, surfaced not dropped.
        let compliance: [ComplianceRecord]
        /// The reading-order / module-map artifact.
        let map: LegibilityMap
    }

    /// Runs all rules and builds the map over already-resolved facts.
    ///
    /// Pure and deterministic — no file or index I/O — so it is fully unit-testable
    /// (via `@testable`). Internal: the module's only public surface is the
    /// ``QualityChecker`` conformance.
    static func analyze(
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

        // Prefer the semantic (IndexStore) graph — real fan-in + over-public —
        // and fall back to the declared Package.swift graph when the index is
        // unavailable or stale.
        var graph = loadDeclaredGraph(cwd: cwd, config: config)
        var overPublic: [OverPublicOccurrence] = []
        if config.useIndexStore,
           let semantic = await resolveSemantics(configuration: configuration, cwd: cwd) {
            if !semantic.graph.modules.isEmpty {
                graph = Self.filterExempt(semantic.graph, exemptModules: config.exemptModules)
            }
            overPublic = semantic.overPublic
        }

        let orientation = discoverOrientation(cwd: cwd, modules: graph.modules)
        let overPublicByModule = Self.countByModule(overPublic)

        let result = Self.analyze(
            graph: graph,
            orientation: orientation,
            overPublic: overPublic,
            overPublicByModule: overPublicByModule,
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
        // A non-package project legitimately has no manifest → empty graph, no error.
        guard FileManager.default.fileExists(atPath: packagePath) else {
            return ModuleGraph(edges: [:])
        }
        let source: String
        do {
            source = try String(contentsOfFile: packagePath, encoding: .utf8)
        } catch {
            Self.logger.warning("Failed to read Package.swift: \(error.localizedDescription, privacy: .public)")
            return ModuleGraph(edges: [:])
        }
        let graph = PackageGraphLoader.declaredGraph(packageSource: source, includingTestTargets: false)
        return Self.filterExempt(graph, exemptModules: config.exemptModules)
    }

    /// Drops exempt modules — and every edge into them — from a graph.
    static func filterExempt(_ graph: ModuleGraph, exemptModules: Set<String>) -> ModuleGraph {
        guard !exemptModules.isEmpty else { return graph }
        var edges: [String: Set<String>] = [:]
        for (from, tos) in graph.edges where !exemptModules.contains(from) {
            let kept = tos.subtracting(exemptModules)
            if !kept.isEmpty { edges[from] = kept }
        }
        return ModuleGraph(edges: edges)
    }

    /// Counts unacknowledged over-public occurrences per module (for the map cards).
    static func countByModule(_ occurrences: [OverPublicOccurrence]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for occ in occurrences where !occ.acknowledged {
            counts[occ.moduleName, default: 0] += 1
        }
        return counts
    }

    /// Opens the IndexStore and resolves the semantic graph + over-public set.
    ///
    /// Returns `nil` when the index is missing or stale — the caller then keeps
    /// the declared-graph result. Never throws: an advisory checker degrades
    /// silently rather than failing.
    private func resolveSemantics(configuration: Configuration, cwd: String) async -> SemanticResolution? {
        let kind = ProjectKind.detect(at: URL(fileURLWithPath: cwd))
        do {
            guard let located = try StoreLocator.locate(projectKind: kind), !located.isStale else {
                return nil
            }
            guard let libPath = IndexStoreSession.findLibIndexStore() else { return nil }
            let session = try await SharedIndexStore.session(storePath: located.url, libPath: libPath)
            let sourceFiles = SourceWalker
                .swiftFiles(under: kind.rootURL, excludePatterns: configuration.excludePatterns)
                .filter { $0.contains("/Sources/") }
            let publicByFile = scanPublicSurface(sourceFiles: sourceFiles, config: configuration.legibility)
            return LegibilityIndexPass.resolve(
                session: session,
                sourceFiles: sourceFiles,
                publicByFile: publicByFile,
                exemptSymbols: configuration.legibility.exemptSymbols
            )
        } catch {
            Self.logger.warning("Legibility index pass unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Runs the SwiftSyntax public-surface scan over the given source files.
    private func scanPublicSurface(sourceFiles: [String], config: LegibilityAnalyzerConfig) -> [String: [PublicSymbol]] {
        let scanner = PublicSurfaceScanner()
        var result: [String: [PublicSymbol]] = [:]
        for file in sourceFiles {
            let source: String
            do {
                source = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                Self.logger.warning("Skipping unreadable source file \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let symbols = scanner.scan(source: source, fileName: file, reservedMarker: config.reservedMarker)
            if !symbols.isEmpty { result[file] = symbols }
        }
        return result
    }

    private func discoverOrientation(cwd: String, modules: Set<String>) -> [ModuleOrientation] {
        let sourcesPath = (cwd as NSString).appendingPathComponent("Sources")
        return modules.sorted().map { module in
            let moduleDir = (sourcesPath as NSString).appendingPathComponent(module)
            return ModuleOrientation(moduleName: module, hasOrientationDoc: hasDocCCatalog(moduleDir: moduleDir))
        }
    }

    private func hasDocCCatalog(moduleDir: String) -> Bool {
        // A module with no source directory on disk simply has no catalog.
        guard FileManager.default.fileExists(atPath: moduleDir) else { return false }
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: moduleDir)
            return entries.contains { $0.hasSuffix(".docc") }
        } catch {
            Self.logger.warning("Failed to list module directory \(moduleDir, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
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
