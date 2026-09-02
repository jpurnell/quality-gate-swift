import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// Compiles the fenced Swift inside `///` and `/** */` doc comments against the module the
/// comment lives in.
///
/// ## Why this is not `doc-code` with a wider file list
///
/// `doc-code` compiles the `.docc` catalogue. This checker compiles the comments the
/// catalogue was copied *from*, and the distinction is not theoretical. Commit `65471d7`
/// repaired 26 articles in this package and found real API drift doing it —
/// `Configuration.default` gone, `limitToFiles` retyped, `{ … }` placeholders that never
/// parsed. It touched no doc comment. The result is visible in one pair of files:
/// `ImplementingCheckers.md` shows a `MyChecker` that declares its helper, imports
/// `QualityGateCore` and returns a real `CheckResult`, *because `doc-code` forced it to*; the
/// `///` comment on `QualityChecker` itself, four directories away, still carries the
/// abbreviated version. `doc-code` repaired the copy and could not see the original, and
/// Quick Help still serves the original.
///
/// ## Three decisions worth knowing before reading a finding
///
/// - **The compilation unit is one fence**, not the doc comment and not the file. Two fences
///   in one doc comment are two independent examples for two independent readers, so a name
///   declared in both is not a defect and no collision detection runs. See
///   ``DocCommentFenceAuditor``.
/// - **The preamble is `Foundation` plus the owning module, and nothing widens it** — not the
///   dependency closure, not `docCode.extraImports`. A doc comment documents one declaration
///   in one module, and the imports its example needs belong in the example, because the
///   reader needs them too.
/// - **Only `swift`-tagged fences are compiled.** Untagged and foreign-tagged fences are
///   never guessed at, and are counted in the coverage line so the silence is legible.
///
/// ## Opt-in, and error severity once opted into
///
/// Sixteen of this repository's twenty doc-comment fences failed when the rule was first
/// measured, and a gate that is red on arrival gets skipped. Enable it with
/// `--check doc-comment-code` or `enabledCheckers`; `--full` is unrelated and never enabled
/// it, because `--full` means "the slow ones too", not "adopt a documentation convention".
///
/// It was briefly default-on — promoted and reverted on 2026-08-27, when a sweep of all 86
/// gate-configured repositories found 12 red carrying 162 errors that the promoting survey
/// had never enumerated. See `CheckerSelection` in QualityGateCore for what the survey missed
/// and what re-promoting requires.
///
/// Once enabled the findings are errors and no knob downgrades them, because a knob that
/// turns a red gate green is a suppression by another name. The one escape hatch is
/// `Configuration.excludedCheckers`, which removes the checker rather than softening it —
/// for a package this checker cannot evaluate at all. `Ignite` is the case: its fence
/// compile stops at a missing `cmark_gfm_extensions` module before any fence is read, so
/// its error count describes the barrier, not the documentation. See ``ArticleAuditor``
/// on why a barrier makes the count meaningless.
public struct DocCommentCodeAuditor: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocCommentCodeAuditor")

    /// Unique identifier for this checker.
    ///
    /// Its own, deliberately, rather than `doc-code`'s. A shared id means the two rules
    /// cannot be red and green independently: `doc-code` was made green by commit `65471d7`
    /// at real cost, and folding sixteen doc-comment failures into the same id would turn it
    /// red again the day this landed.
    public let id = "doc-comment-code"

    /// Human-readable name for this checker.
    public let name = "Doc Comment Code Compiler"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Fenced Swift in `///` and `/** */` doc comments must compile against the module the comment lives in — the unit is one fence (opt-in)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.documentation

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.documentation

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Safe to run in the concurrent group — and that placement is what orders it correctly.
    ///
    /// `CheckerRunner` runs every non-parallel-safe checker to completion first, and
    /// `BuildChecker` declares itself non-parallel-safe, so declaring this checker
    /// parallel-safe is precisely what guarantees it reads a finished `.build/debug` instead
    /// of racing `swift build` writing into it. Declaring `false` would order it identically
    /// and serialise it against every other checker for nothing.
    ///
    /// Each fence is compiled in its own `NSTemporaryDirectory()` working directory; nothing
    /// is written into the build tree.
    public var isParallelSafe: Bool { true }

    /// Hermetic: the verdict is a function of the working tree and the module built from it.
    ///
    /// No calendar, no network, no service. The one case that might otherwise argue for
    /// `Hermeticity/external` — a module that was never built — is reported as a note with
    /// its reason, so the classification does not have to carry it and a genuine
    /// documentation failure keeps its authority to block the commit.
    public var hermeticity: Hermeticity { .hermetic }

    /// Creates a new auditor.
    public init() {}

    // MARK: - Scope

    /// The module a source file belongs to, or `nil` when it is not in one.
    ///
    /// `Sources/<Module>/…`, the same derivation `ArticleDiscovery` uses for catalogues.
    /// `Tests/` is outside the scope on purpose: it carries no doc-comment fences at all in
    /// this package, exposes no public API, and its targets leave no `.swiftmodule` in
    /// `.build/debug` to compile against.
    static func owningModule(of file: URL, projectRoot: URL) -> String? {
        let root = projectRoot.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        let components = path.dropFirst(root.count).split(separator: "/")
        guard components.count >= 3, SourceLayout.isSourceRoot(String(components[0])) else { return nil }
        return String(components[1])
    }

    /// Every first-party `.swift` file under `Sources/`, grouped by owning module.
    static func modules(projectRoot: URL, configuration: Configuration) -> [String: [URL]] {
        let roots = SourceLayout.spellings.map {
            projectRoot.appendingPathComponent($0, isDirectory: true)
        }
        guard let walker = roots.lazy.compactMap({ root in
            FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        }).first else {
            return [:]
        }

        var byModule: [String: [URL]] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard !configuration.excludePatterns.contains(where: { url.path.contains($0) }) else {
                continue
            }
            guard let module = owningModule(of: url, projectRoot: projectRoot) else { continue }
            byModule[module, default: []].append(url)
        }
        return byModule.mapValues { $0.sorted { $0.path < $1.path } }
    }

    /// The preamble for a module's fences: `Foundation` and the module, in that order.
    ///
    /// Takes the configuration and ignores every widening knob in it, on purpose.
    /// `DocCodeConfig.extraImports` exists because a *catalogue* legitimately spans two
    /// products without saying so in every block. A doc comment has no such excuse: it
    /// documents one declaration in one module. A global extra-imports knob here would be a
    /// suppression with a nicer name, and it would erase this repository's single largest
    /// documentation defect — ten `## Usage` blocks that a reader cannot copy because they
    /// never say which module to import.
    ///
    /// - Parameters:
    ///   - module: The module the doc comment lives in.
    ///   - configuration: Taken and deliberately not read, so that a later reader who goes
    ///     looking for the knob finds this comment instead of adding one.
    /// - Returns: Exactly two imports, always.
    static func preambleImports(module: String, configuration: Configuration) -> [String] {
        ["Foundation", module]
    }

    // MARK: - Cache

    /// Inputs whose change could change the verdict.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        Self.cacheInputs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration)
    }

    /// Inputs whose change could change the verdict, for a given project root.
    ///
    /// Deliberately over-inclusive, on `CacheInputs`' own stated grounds: over-including
    /// costs a miss, under-including serves a wrong verdict.
    ///
    /// 1. **Every first-party `.swift` file.** Simpler than `doc-code`, where the corpus and
    ///    the API are two file sets — here they are the *same* set. The fences live in the
    ///    sources, and the API they are checked against is compiled from those sources.
    /// 2. **The built module artefacts**, for every module under `Sources/`. This is the case
    ///    where a module is rebuilt without a first-party source change — a dependency bump,
    ///    a toolchain-driven re-emit — and without it a cached pass could outlive the API it
    ///    certified. Taken for every module rather than only the ones carrying a fence,
    ///    because narrowing it would mean parsing the whole tree to compute a cache key.
    /// 3. **`Package.swift` and `Package.resolved`.** The manifest decides the language mode
    ///    and `swiftSettings`, and a fence that passes under Swift 5 can fail under Swift 6.
    ///
    /// The salt carries the whole configuration, so any knob change invalidates too.
    public static func cacheInputs(projectRoot: URL, configuration: Configuration) -> CacheInputs? {
        let byModule = modules(projectRoot: projectRoot, configuration: configuration)
        guard !byModule.isEmpty else { return nil }

        var files = DocCodeAuditor.swiftSources(
            under: projectRoot, excluding: configuration.excludePatterns)
        for manifest in ["Package.swift", "Package.resolved"] {
            files.append(projectRoot.appendingPathComponent(manifest).path)
        }
        for module in byModule.keys.sorted() {
            guard let searchPath = ArticleDiscovery.moduleSearchPath(
                projectRoot: projectRoot, moduleName: module, configuration: configuration
            ) else { continue }
            files += DocCodeAuditor.builtModuleFiles(searchPath: searchPath, moduleName: module)
        }
        return CacheInputs(files: files, salt: DocCodeAuditor.configurationSalt(configuration))
    }

    // MARK: - Run

    /// Runs the check against the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        try await check(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration)
    }

    /// Runs the check against a given project root.
    ///
    /// - Parameters:
    ///   - projectRoot: The package root.
    ///   - configuration: The gate configuration.
    /// - Returns: A result carrying one diagnostic per finding plus, always, a coverage note
    ///   for every file that has a doc fence at all — found reported separately from checked,
    ///   because an untagged fence that later fills with Swift shows up as a count that did
    ///   not move while a file's examples did, and that is the only warning anyone gets.
    public func check(projectRoot: URL, configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now

        let byModule = Self.modules(projectRoot: projectRoot, configuration: configuration)
        guard !byModule.isEmpty else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No Sources/ directory; nothing to compile.",
                        ruleId: "doc-comment-code-skip")
                ],
                duration: ContinuousClock.now - start)
        }

        var diagnostics: [Diagnostic] = []
        var work: [FenceJob] = []

        // Derived once, not once per module. Both walk the build tree, and this package has
        // 116 modules — recomputing them inside the loop turned a sub-second checker into a
        // twenty-second one, all of it re-listing the same `.build/checkouts`.
        let headerSearchPaths = DocCodeAuditor.headerSearchPaths(
            projectRoot: projectRoot, configuration: configuration)
        let moduleMapFiles = DocCodeAuditor.generatedModuleMaps(projectRoot: projectRoot)

        // Read once for the same reason: "was this plugin built" and "what does it
        // register" have one answer per run, and the answer is what tells a missing
        // build apart from a missing `providingMacros` entry when the compiler calls
        // both of them "plugin for module not found".
        let macroEnvironment = MacroDiagnosis.Environment.read(
            projectRoot: projectRoot,
            buildDirectory: configuration.docCode.moduleSearchPath
                ?? projectRoot.appendingPathComponent(".build/debug").path)

        for module in byModule.keys.sorted() {
            let files = byModule[module] ?? []
            let censuses = files.compactMap { Self.census(of: $0) }.filter { $0.found > 0 }
            guard !censuses.isEmpty else { continue }

            diagnostics += censuses.map {
                Diagnostic(
                    severity: .note,
                    message: $0.coverageMessage,
                    filePath: $0.filePath,
                    ruleId: "doc-comment-code.coverage")
            }

            let fences = censuses.flatMap(\.checkable)
            guard !fences.isEmpty else { continue }

            guard let searchPath = ArticleDiscovery.moduleSearchPath(
                projectRoot: projectRoot, moduleName: module, configuration: configuration
            ) else {
                // Without the module every fence fails with `no such module` — a wall of
                // findings about this checker's own environment, indistinguishable at a
                // glance from findings about the documentation. Say what actually happened.
                //
                // A warning, not a note, because a note does not reach the summary line: the
                // run printed PASSED while examining nothing, which is the vacuous pass
                // `doc-lint` was already hardened against. Not an error, because unlike a
                // missing catalogue this is not a fact about the project — it is the order
                // the checkers ran in, and the full gate fixes it by running `build` first.
                // It fires on a standalone `--check doc-comment-code`, which is exactly the
                // invocation that would otherwise be believed.
                diagnostics.append(
                    Diagnostic(
                        severity: .warning,
                        message: """
                            Skipped \(module): no built module found under .build/debug, so no \
                            fence in it was examined — this is not a pass. Run the build first, \
                            or run the full gate, which builds before this checker. This checker \
                            compiles documentation against the module; it does not build it.
                            """,
                        ruleId: "doc-comment-code.module-unavailable"))
                continue
            }

            let mode = ManifestLanguageMode.read(projectRoot: projectRoot, target: module)
            if !mode.isDetermined {
                diagnostics.append(
                    Diagnostic(
                        severity: .note,
                        message: "\(module): \(mode.explanation)",
                        ruleId: "doc-comment-code.language-mode"))
            }
            if !mode.unrecognisedSettings.isEmpty {
                diagnostics.append(
                    Diagnostic(
                        severity: .note,
                        message: """
                            \(module): these swiftSettings were not translated into compiler \
                            flags, so documentation is checked under slightly different rules \
                            than the build: \(mode.unrecognisedSettings.joined(separator: ", ")).
                            """,
                        ruleId: "doc-comment-code.language-mode"))
            }

            var options = DocCodeAuditOptions()
            options.moduleSearchPath = searchPath
            // A package's own macros are as unreachable as swift-testing's were without their
            // plugin: the fence fails on a missing implementation rather than on anything the
            // author wrote, and the natural repair is an exemption the gate did not earn.
            options.toolchainFlags += MacroPlugins.flags(
                projectRoot: projectRoot, buildDirectory: searchPath)
            options.imports = Self.preambleImports(module: module, configuration: configuration)
            options.languageFlags = mode.flags
            options.headerSearchPaths = headerSearchPaths
            options.moduleMapFiles = moduleMapFiles

            work += fences.map { FenceJob(fence: $0, options: options) }
        }

        // Every fence in the package compiled in one task group, rather than one group per
        // module. The distinction is the whole cost model: a fence costs the same 0.24s
        // whatever its length, because essentially all of it is module loading, and this
        // package spreads its twenty fences across fourteen modules. Grouping per module
        // would run them almost entirely serially — fourteen groups of one or two.
        let verdicts = await audit(work)
        let checked = verdicts.count
        for verdict in verdicts {
            diagnostics += Self.diagnostics(for: verdict, macros: macroEnvironment)
        }

        let failed = diagnostics.contains { $0.severity == .error }
        Self.logger.info("doc-comment-code compiled \(checked, privacy: .public) doc-comment fences")

        // Nothing was compiled, so there is nothing to pass. Reporting `.passed` here would
        // be the worst available answer: a green check that means only that no fence was
        // ever reached.
        let status: CheckResult.Status = failed ? .failed : (checked == 0 ? .skipped : .passed)

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - start)
    }

    /// The census for one file, or `nil` when it cannot be read or cannot contain a fence.
    ///
    /// An unreadable file is a dropped file rather than a failed run — the rest of the module
    /// is still worth checking — but it is logged, because a file this checker silently never
    /// opened is a file whose examples are silently never checked.
    ///
    /// The prefilter is exact rather than heuristic, which is the only reason it is allowed to
    /// exist here. A fenced block opens with a run of backticks or tildes, so a file whose
    /// text contains neither substring cannot hold one — the skip cannot cost a finding, only
    /// a parse. It costs a great deal of parsing: 262 of this package's 288 source files carry
    /// no fence of any kind, and building a syntax tree for each of them was twenty seconds of
    /// a twenty-four second check.
    private static func census(of file: URL) -> DocCommentCensus? {
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("```") || text.contains("~~~") else { return nil }
            return DocCommentFenceExtractor.census(in: text, path: file.path)
        } catch {
            logger.warning("Could not read \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// One fence and the flags its owning module needs, so fences from different modules can
    /// share a single task group.
    private struct FenceJob: Sendable {
        let fence: DocCommentFence
        let options: DocCodeAuditOptions
    }

    /// Compiles fences concurrently, bounded by the machine's processor count.
    ///
    /// Per-fence compilation is dominated by fixed per-invocation overhead — module loading,
    /// essentially — so a 2-line fence and a 16-line fence cost the same. That is why the
    /// work parallelises so well and why batching would buy nothing: one fence per program is
    /// also what makes line attribution direct arithmetic instead of a line map.
    private func audit(_ work: [FenceJob]) async -> [DocCommentFenceVerdict] {
        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)

        return await withTaskGroup(of: DocCommentFenceVerdict?.self) { group in
            var next = 0
            while next < min(limit, work.count) {
                let job = work[next]
                group.addTask { Self.auditSafely(job) }
                next += 1
            }

            var results: [DocCommentFenceVerdict] = []
            while let verdict = await group.next() {
                if let verdict { results.append(verdict) }
                if next < work.count {
                    let job = work[next]
                    group.addTask { Self.auditSafely(job) }
                    next += 1
                }
            }
            return results.sorted {
                $0.filePath == $1.filePath
                    ? $0.fenceOpenLine < $1.fenceOpenLine
                    : $0.filePath < $1.filePath
            }
        }
    }

    /// Compiles one fence, turning an unwritable temporary directory into a dropped fence
    /// rather than a failed run.
    private static func auditSafely(_ job: FenceJob) -> DocCommentFenceVerdict? {
        do {
            return try DocCommentFenceAuditor.audit(job.fence, options: job.options)
        } catch {
            logger.warning("Could not compile the doc fence at \(job.fence.filePath, privacy: .public):\(job.fence.openLine, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Reporting

    /// Turns one fence's verdict into diagnostics.
    static func diagnostics(
        for verdict: DocCommentFenceVerdict,
        macros: MacroDiagnosis.Environment = .unknown
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let attribution = verdict.declarationName.map { " on '\($0)'" } ?? ""

        if let barrier = verdict.barrier {
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        The doc comment example\(attribution) stopped at a barrier: \(barrier). \
                        Every error behind it is invisible, so this fence's error count means \
                        nothing until the barrier is resolved.
                        """,
                    filePath: verdict.filePath,
                    lineNumber: verdict.fenceOpenLine,
                    ruleId: "doc-comment-code.barrier",
                    suggestedFix: """
                        If the module is a legitimate dependency, add the import to the fence \
                        — the reader needs that line too. If it is not, the example belongs in \
                        a module that can reach it. Do not exempt past a barrier: an exemption \
                        there does not hide one fence, it hides everything behind it.
                        """))
        }

        for error in verdict.compileErrors {
            if let symbol = DocCodeAuditor.undefinedSymbol(in: error.message) {
                diagnostics.append(
                    Diagnostic(
                        severity: .error,
                        message: """
                            The doc comment example\(attribution) references '\(symbol)', which \
                            nothing in the fence defines and the preamble does not import.
                            """,
                        filePath: verdict.filePath,
                        lineNumber: error.fileLine,
                        ruleId: "doc-comment-code.undefined-symbol",
                        suggestedFix: """
                            Bind it in the fence, or add the `import` the example needs. The \
                            preamble is Foundation plus this module only, on purpose: whatever \
                            the fence has to say to compile is exactly what a reader copying \
                            it out of Quick Help has to type.
                            """))
            } else if let macro = MacroDiagnosis.parse(error.message) {
                // The compiler blames the plugin in both of the situations that produce
                // this message, and only one of them is about the plugin. Say which.
                diagnostics.append(
                    Diagnostic(
                        severity: .error,
                        message: """
                            The doc comment example\(attribution) uses `@\(macro.macroName)`, \
                            which did not expand. \
                            \(MacroDiagnosis.explain(macro, in: macros))
                            """,
                        filePath: verdict.filePath,
                        lineNumber: error.fileLine,
                        ruleId: "doc-comment-code.macro-unexpanded",
                        suggestedFix: """
                            This is a defect in the package, not in the example. Do not mark the \
                            fence illustrative to silence it — the example is correct and the \
                            macro is not reaching it.
                            """))
            } else {
                diagnostics.append(
                    Diagnostic(
                        severity: .error,
                        message: "The doc comment example\(attribution) does not compile: \(error.message)",
                        filePath: verdict.filePath,
                        lineNumber: error.fileLine,
                        ruleId: "doc-comment-code.compile-error",
                        suggestedFix: """
                            Fix the example, or mark the fence <!-- docs:illustrative --> if it \
                            is genuinely a fragment rather than something a reader could run. \
                            The marker is a human edit and is never applied by a tool.
                            """))
            }
        }

        return diagnostics
    }
}
