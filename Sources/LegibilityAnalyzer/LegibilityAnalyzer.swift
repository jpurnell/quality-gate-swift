import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore
import IndexStoreInfra
import IJSSensor

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

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Advisory (never gates): central-but-unoriented modules, dependency cycles, over-public surface; emits a reading-order / module-map artifact"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.correctness

    /// What this checker's findings are about — see `CheckerKind`.
    /// `convention`: naming and length thresholds judge how code reads, which is the author's call.
    public let kind = CheckerKind.convention

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly
    /// Read-only over parsed sources; safe to run concurrently.
    public var isParallelSafe: Bool { true }

    /// Creates a legibility analyzer.
    public init() {}

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

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

    /// Builds a per-module orientation card for every module in the graph.
    ///
    /// Pure and deterministic. `dependsOn`/`reliedOnBy`/`role` are factual (from
    /// the graph). `whatItDoes` prefers the module's human-authored Master Plan
    /// description, then a pointer to its DocC overview, else `nil`; `why`
    /// explains the module's structural role. Richer LLM prose is a later tier.
    static func orientationCards(
        graph: ModuleGraph,
        orientation: [ModuleOrientation],
        descriptions: [String: String] = [:],
        timestamp: Date
    ) -> [ModuleOrientationCard] {
        let hasDoc = Dictionary(
            orientation.map { ($0.moduleName, $0.hasOrientationDoc) },
            uniquingKeysWith: { first, _ in first }
        )
        return graph.modules.sorted().map { module in
            let fanIn = graph.fanIn(module)
            let role = LegibilityMapBuilder.inferRole(fanIn: fanIn, fanOut: graph.fanOut(module))
            let whatItDoes = descriptions[module]
                ?? (hasDoc[module] == true ? "See the module's DocC overview." : nil)
            return ModuleOrientationCard(
                moduleID: module,
                whatItDoes: whatItDoes,
                why: templateWhy(role: role, fanIn: fanIn),
                dependsOn: graph.dependencies(of: module).sorted(),
                reliedOnBy: graph.dependents(of: module).sorted(),
                role: role,
                source: .template,
                generatedAt: timestamp
            )
        }
    }

    /// A deterministic structural explanation of a module's role.
    static func templateWhy(role: String, fanIn: Int) -> String? {
        switch role {
        case "foundation":
            return "A foundational module — \(fanIn) other module\(fanIn == 1 ? "" : "s") build on it."
        case "entry-point":
            return "An entry point — nothing else in the package depends on it."
        case "orchestrator":
            return "Coordinates several modules; little depends on it directly."
        case "intermediate":
            return "A mid-layer module — it both depends on and is depended upon."
        case "isolated":
            return "Standalone — no internal dependencies in either direction."
        default:
            return nil
        }
    }

    /// Assembles the full corpus orientation report for the current project:
    /// per-module cards (with Master Plan descriptions where available), the
    /// package's "built from" dependencies (for cross-package inversion by the
    /// dashboard), and the package-level Mission. Prefers the semantic graph,
    /// falls back to the declared graph — never throws.
    public func orientationReport(
        configuration: Configuration,
        timestamp: Date,
        projectID: String
    ) async -> OrientationReport {
        let cwd = configuration.resolvedProjectRoot.path
        var graph = loadDeclaredGraph(cwd: cwd, config: configuration.legibility)
        if configuration.legibility.useIndexStore,
           let semantic = await resolveSemantics(configuration: configuration, cwd: cwd),
           !semantic.graph.modules.isEmpty {
            graph = Self.filterExempt(semantic.graph, exemptModules: configuration.legibility.exemptModules)
        }
        let orientation = discoverOrientation(cwd: cwd, modules: graph.modules)

        let masterPlan = loadMasterPlan(cwd: cwd, config: configuration.status)
        let descriptions = masterPlan.map(MasterPlanReader.descriptions) ?? [:]

        let cards = Self.orientationCards(
            graph: graph,
            orientation: orientation,
            descriptions: descriptions,
            timestamp: timestamp
        )

        let packageSource = loadPackageSource(cwd: cwd)
        let packageDependsOn = packageSource.map(PackageGraphLoader.externalPackageDependencies) ?? []

        // Package "what it does": the `// legibility:description:` comment in
        // Package.swift → the Master Plan Mission → the README lead (Phase 1:
        // repos without our conventions still get prose) → nil.
        let packageSummary = packageSource.flatMap(PackageGraphLoader.packageDescription)
            ?? masterPlan.flatMap(MasterPlanReader.mission)
            ?? readmeLead(cwd: cwd)

        return OrientationReport(
            projectID: projectID,
            timestamp: timestamp,
            cards: cards,
            packageDependsOn: packageDependsOn,
            packageSummary: packageSummary
        )
    }

    /// The output format for ``orientDocument(configuration:packageName:watermarked:format:)``.
    public enum OrientFormat: String, Sendable {
        /// One-page human-readable Markdown.
        case markdown = "md"
        /// Deterministic pretty JSON.
        case json
        /// A self-contained single-file HTML report.
        case html
    }

    /// Builds the self-contained `orient` page for the package at the current
    /// directory — the zero-config onboarding pipeline (Phase 1 §3).
    ///
    /// Same graph resolution as ``check(configuration:)`` (semantic when an
    /// index store already exists and `useIndexStore` is on, declared graph
    /// otherwise), but no diagnostics, no artifact writes, no corpus.
    ///
    /// - Parameters:
    ///   - configuration: The effective configuration for the analyzed package.
    ///   - packageName: Display name for the page heading.
    ///   - watermarked: true when the analyzed repo declares no config of its
    ///     own — the output then carries the §2b provenance watermark.
    ///   - format: Markdown or JSON.
    /// - Returns: The rendered document.
    /// - Throws: An encoding error for the JSON format only.
    public func orientDocument(
        configuration: Configuration,
        packageName: String,
        watermarked: Bool,
        format: OrientFormat
    ) async throws -> String {
        let config = configuration.legibility
        let cwd = configuration.resolvedProjectRoot.path

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
        let map = LegibilityMapBuilder.build(
            graph: graph,
            orientation: orientation,
            overPublicByModule: Self.countByModule(overPublic)
        )

        let packageSource = loadPackageSource(cwd: cwd)
        let masterPlan = loadMasterPlan(cwd: cwd, config: configuration.status)
        let summary = packageSource.flatMap(PackageGraphLoader.packageDescription)
            ?? masterPlan.flatMap(MasterPlanReader.mission)
            ?? readmeLead(cwd: cwd)
        let builtFrom = packageSource.map(PackageGraphLoader.externalPackageDependencies) ?? []

        let document = OrientDocument(
            packageName: packageName,
            summary: summary,
            builtFrom: builtFrom,
            map: map,
            watermarked: watermarked
        )
        switch format {
        case .markdown:
            return OrientRenderer.markdown(document)
        case .json:
            return try OrientRenderer.json(document)
        case .html:
            return OrientRenderer.html(document)
        }
    }

    /// The README's first meaningful paragraph, or nil when absent.
    private func readmeLead(cwd: String) -> String? {
        let path = (cwd as NSString).appendingPathComponent("README.md")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            return READMELeadExtractor.lead(from: try String(contentsOfFile: path, encoding: .utf8))
        } catch {
            Self.logger.warning("Failed to read README.md: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Reads the project's Master Plan markdown, or `nil` when absent/unreadable.
    private func loadMasterPlan(cwd: String, config: StatusAuditorConfig) -> String? {
        let path = (cwd as NSString)
            .appendingPathComponent(config.guidelinesPath)
            .appending("/\(config.masterPlanPath)")
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            Self.logger.warning("Failed to read Master Plan at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The project's `Package.swift` source, or `nil` when absent/unreadable.
    private func loadPackageSource(cwd: String) -> String? {
        let packagePath = (cwd as NSString).appendingPathComponent("Package.swift")
        guard FileManager.default.fileExists(atPath: packagePath) else { return nil }
        do {
            return try String(contentsOfFile: packagePath, encoding: .utf8)
        } catch {
            Self.logger.warning("Failed to read Package.swift: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Runs the analyzer against the current project.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now
        let config = configuration.legibility
        let cwd = configuration.resolvedProjectRoot.path

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
            // Scoped to `Sources/` deliberately, and this is not the hardcoded-`Sources/`
            // defect that was swept out of the code-kind checkers. Those bounded a walk to a
            // directory and so never examined rules that apply everywhere. This measures the
            // *public API surface* and whether the modules publishing it carry an orientation
            // doc. A test target's `public` symbols are not API anybody imports, so widening
            // this would report every test module as undocumented and make the metric mean
            // less, not more. Stated here because an unexplained filter is indistinguishable
            // from the defect, and the next reader will otherwise "fix" it.
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
            // WriteGuard backstop (Phase 1): in foreign mode the CLI redirects
            // artifactPath into the overlay; a path that still lands in the
            // analyzed repo is a bug this trap refuses to paper over.
            try WriteGuard.validate(path: basePath)
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
