import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// Compiles the fenced Swift in DocC articles against the built module.
///
/// Documentation code is unverified by default: nothing compiles it, so it drifts silently
/// from the API it describes, and the first person to notice is a reader who copies a block
/// that cannot build. A sweep of one 73-article catalogue found 2,092 errors across 67 of
/// them — including three constructors documented with argument labels the API never had,
/// and a type documented as public that is internal.
///
/// ## The compilation unit is the article
///
/// Every checked block in an article, concatenated in document order, must compile as one
/// file-scope program — so an article pastes into a playground and runs. Under that rule a
/// later block referring to an earlier binding is *correct* and must keep working, and two
/// independent examples that both open with `let data = …` are *a defect in the article*
/// whose repair is a rename (`salesData`, `returnsData`), not an annotation.
///
/// ## Not a replacement for the other documentation checkers
///
/// This checker is complementary to `doc-lint` and `doc-coverage`, and merging them would
/// lose all three:
///
/// - `doc-lint` runs `swift package generate-documentation` and parses DocC's own
///   diagnostics — unresolved topic references, malformed markup. It never compiles a fence.
/// - `doc-coverage` asks whether public API carries a doc comment. It never reads what the
///   comment says.
/// - `doc-code` asks whether the code a reader would copy actually builds. It is blind to
///   everything outside a fence, and blind to code that compiles while being wrong.
///
/// Each is blind exactly where the others see.
public struct DocCodeAuditor: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocCodeAuditor")

    /// Unique identifier for this checker.
    public let id = "doc-code"

    /// Human-readable name for this checker.
    public let name = "Documentation Code Compiler"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Fenced Swift in DocC articles must compile against the built module — the article is one program"

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
    /// `CheckerRunner` runs every non-parallel-safe checker to completion first, then the
    /// parallel-safe ones together. `BuildChecker` declares itself non-parallel-safe, so
    /// declaring this checker parallel-safe is precisely what guarantees it reads a finished
    /// `.build/debug` instead of racing `swift build` writing into it. Declaring `false`
    /// would order it identically and serialise a minutes-long checker against every other
    /// one for nothing.
    ///
    /// It never writes to the build tree: each article is assembled and typechecked in its
    /// own `NSTemporaryDirectory()` working directory, which is also what lets the articles
    /// themselves be audited concurrently.
    public var isParallelSafe: Bool { true }

    /// Hermetic: the verdict is a function of the working tree and the module built from it.
    ///
    /// No calendar, no network, no service. The one input that is not source — the built
    /// module — is derived from the same commit, and the toolchain is already folded into
    /// the cache's gate identity, so a byte-identical commit checked twice returns the same
    /// answer. The case that might otherwise argue for `Hermeticity/external` — a module
    /// that was never built — is handled explicitly as a `.skipped` result carrying its
    /// reason, so the classification does not have to carry it, and a genuine documentation
    /// failure keeps its authority to block the commit.
    public var hermeticity: Hermeticity { .hermetic }

    /// Creates a new auditor.
    public init() {}

    /// Inputs whose change could change the verdict.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        Self.cacheInputs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration)
    }

    /// Inputs whose change could change the verdict, for a given project root.
    ///
    /// Three groups, deliberately over-inclusive, because over-including only costs an extra
    /// cache miss while under-including is the one way a cache can serve a verdict that is
    /// simply wrong:
    ///
    /// 1. **The articles.** The obvious input, and the one a source-only helper misses —
    ///    `SourceCacheInputs.wholeSource` walks `.swift` files, so relying on it alone would
    ///    let an edited article reuse a cached pass.
    /// 2. **The module.** The verdict is a claim about an API surface. Every first-party
    ///    Swift source covers the case where the module is rebuilt from them; the built
    ///    artefacts cover the case where it is not.
    /// 3. **The manifest.** It decides the language mode and `swiftSettings`, and the same
    ///    article passes under Swift 5 and fails under Swift 6.
    ///
    /// The salt carries the whole configuration, so any knob change invalidates too.
    public static func cacheInputs(projectRoot: URL, configuration: Configuration) -> CacheInputs? {
        let catalogues = ArticleDiscovery.catalogues(projectRoot: projectRoot, configuration: configuration)
        guard !catalogues.isEmpty else { return nil }

        var files = catalogues.flatMap(\.articles).map(\.path)
        files += swiftSources(under: projectRoot, excluding: configuration.excludePatterns)
        for manifest in ["Package.swift", "Package.resolved"] {
            files.append(projectRoot.appendingPathComponent(manifest).path)
        }
        for catalogue in catalogues {
            guard let searchPath = ArticleDiscovery.moduleSearchPath(
                projectRoot: projectRoot, moduleName: catalogue.moduleName, configuration: configuration
            ) else { continue }
            files += builtModuleFiles(searchPath: searchPath, moduleName: catalogue.moduleName)
        }
        return CacheInputs(files: files, salt: configurationSalt(configuration))
    }

    /// Every first-party `.swift` file, which together define the API the articles document.
    ///
    /// Scoped to `Sources` and `Tests` rather than the whole root, because the root descends
    /// into `.build/checkouts` — thousands of dependency files, and a fingerprint nobody
    /// would wait for. A dependency change reaches the fingerprint via `Package.resolved`.
    static func swiftSources(under projectRoot: URL, excluding patterns: [String]) -> [String] {
        let manager = FileManager.default
        var files: [String] = []
        for subdirectory in SourceLayout.spellings + ["Tests"] {
            let directory = projectRoot.appendingPathComponent(subdirectory, isDirectory: true)
            guard let walker = manager.enumerator(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            files += walker.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .map(\.path)
                .filter { path in !patterns.contains { path.contains($0) } }
        }
        return files
    }

    /// Header search paths for the C targets the built modules depend on.
    ///
    /// Without these, an article that opens `import <Module>` never reaches typechecking:
    /// clang cannot find `_SwiftSyntaxCShims`, the compiler reports
    /// `<unknown>:0: error: missing required module`, and every finding behind that is a
    /// finding the checker did not make. Clang looks for a `module.modulemap` in any header
    /// search path, which is what `-Xcc -I<dir>` buys.
    ///
    /// Derived by walking `.build/checkouts/<package>/Sources/<target>/` and keeping every
    /// directory that carries a `module.modulemap`. Both shapes SwiftPM uses are accepted:
    /// under `include/` for a C target with a hand-written modulemap (the swift-syntax
    /// shims), and beside the sources for a system-library target (`CSQLite`). Requiring
    /// `include/` missed the second, and the article importing it stopped dead at
    /// `missing required module 'CSQLite'`.
    ///
    /// **Why not read the build manifest**, which is where these flags authoritatively live:
    /// because it is the less portable of the two here. Under SwiftPM's Swift Build engine
    /// `.build/debug` is a symlink to `.build/out/Products/Debug`, there is no
    /// `.build/debug.yaml`, and the only llbuild manifest on disk sits under
    /// `.build/index-build/` — an artifact of whether an index build happened to run. A
    /// checker keyed to that would be reading another tool's incidental state.
    ///
    /// Over-inclusive on purpose: it offers clang search paths for C targets an article may
    /// never touch. That is the same trade ``cacheInputs(projectRoot:configuration:)`` makes
    /// — over-including costs a search path, under-including costs a wrong verdict.
    ///
    /// - Returns: The derived directories, plus any configured in `docCode.headerSearchPaths`.
    static func headerSearchPaths(projectRoot: URL, configuration: Configuration) -> [String] {
        let manager = FileManager.default
        let checkouts = projectRoot.appendingPathComponent(".build/checkouts", isDirectory: true)
        var found: [String] = []

        // A bounded descent rather than a recursive enumeration: `.build/checkouts` holds
        // every dependency's whole source tree, and walking it would cost thousands of
        // stats to answer a question the layout already answers in four levels.
        // silent: a package with no resolved dependencies has no .build/checkouts to read
        let resolved = (try? manager.contentsOfDirectory(
            at: checkouts, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []

        // The project itself, on the same footing as any dependency. A `.systemLibrary` target
        // is declared in the package that consumes it and commits its modulemap in-tree, so it
        // never appears under `.build/checkouts` — reading only the checkouts made a package's
        // own C target invisible, and every fence importing it stopped at
        // `missing required module`. The descent is identical; only the starting set widens.
        //
        // Path-based dependencies widen it again: `.package(path: "../Sibling")` is never
        // checked out, so it is neither the project root nor a checkout. SwiftPM records
        // those in `.build/workspace-state.json`, which is where they are read from.
        let packages = [projectRoot] + resolved + localDependencies(projectRoot: projectRoot)
        for package in packages {
            // SwiftPM does not require the directory to be called `Sources`, and a dependency's
            // layout is not ours to choose. `mlx-swift` uses `Source`, singular; C-heavy
            // packages wrapped for SwiftPM sometimes use `src`. Hardcoding one spelling made
            // every fence importing such a module stop at a barrier — and the barrier said the
            // count meant nothing, correctly, while the cause was this function looking in a
            // directory that did not exist. Three `stat`s per package, against a wrong verdict.
            for spelling in ["Sources", "Source", "src"] {
                let sources = package.appendingPathComponent(spelling, isDirectory: true)
                // silent: a checkout with no directory of this name contributes no header paths, which is the ordinary case for two of the three spellings
                let targets = (try? manager.contentsOfDirectory(
                    at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for target in targets {
                    for directory in [target.appendingPathComponent("include", isDirectory: true), target] {
                        // SAFETY: CLI tool checks a dependency checkout for a C target's modulemap
                        if manager.fileExists(atPath: directory.appendingPathComponent("module.modulemap").path) {
                            found.append(directory.path)
                        }
                    }
                }
            }
        }

        return found.sorted() + configuration.docCode.headerSearchPaths
    }

    /// Directories of path-based dependencies, from SwiftPM's workspace state.
    ///
    /// A `.package(path:)` dependency is never copied into `.build/checkouts`, so a search
    /// of the checkouts cannot see it. SwiftPM records it in `.build/workspace-state.json`
    /// with `kind` `fileSystem` and an absolute location.
    ///
    /// - Parameter projectRoot: The package being audited.
    /// - Returns: Absolute directories of local dependencies, or empty when there are none
    ///   — which is the ordinary case, and not an error.
    static func localDependencies(projectRoot: URL) -> [URL] {
        let state = projectRoot.appendingPathComponent(".build/workspace-state.json")
        // silent: a package that has never been built, or has no path dependencies, simply
        // has no workspace state to read, and contributes no directories
        guard let data = try? Data(contentsOf: state),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let object = root["object"] as? [String: Any],
              let dependencies = object["dependencies"] as? [[String: Any]] else { return [] }

        var found: [URL] = []
        for dependency in dependencies {
            guard let reference = dependency["packageRef"] as? [String: Any],
                  let kind = reference["kind"] as? String,
                  kind == "fileSystem" || kind == "local",
                  let location = reference["location"] as? String else { continue }
            found.append(URL(fileURLWithPath: location))
        }
        return found
    }

    /// Modulemaps SwiftPM generated for C targets that do not ship one.
    ///
    /// Separate from ``headerSearchPaths(projectRoot:configuration:)`` because they need a
    /// different flag: a generated modulemap names its umbrella header by absolute path and
    /// lives nowhere near it, so a header search path cannot find it and
    /// `-fmodule-map-file=` must name it outright.
    ///
    /// Both layouts are accepted, for the same reason
    /// ``ArticleDiscovery/moduleSearchPath(projectRoot:moduleName:configuration:)`` accepts
    /// both: which one is on disk is a property of the SwiftPM version, not of the project.
    ///
    /// - Returns: Absolute paths of every generated modulemap, or an empty array when the
    ///   package has none — which is the ordinary case for a package with no C dependencies.
    static func generatedModuleMaps(projectRoot: URL) -> [String] {
        let manager = FileManager.default
        var found: [String] = []

        // Swift Build: one directory of `<Target>.modulemap`.
        let generated = projectRoot.appendingPathComponent(
            ".build/out/Intermediates.noindex/GeneratedModuleMaps", isDirectory: true)
        // silent: absent under the classic llbuild layout, which the next block reads instead
        found += ((try? manager.contentsOfDirectory(
            at: generated, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "modulemap" }
            .map(\.path)

        // Classic llbuild: `<Target>.build/module.modulemap` beside the products.
        let debug = projectRoot.appendingPathComponent(".build/debug", isDirectory: true)
        // silent: an unbuilt package has no .build/debug, already reported as a skip with its reason
        for directory in (try? manager.contentsOfDirectory(
            at: debug, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            guard directory.pathExtension == "build" else { continue }
            let modulemap = directory.appendingPathComponent("module.modulemap")
            // SAFETY: CLI tool checks the project's own build tree for a generated modulemap
            if manager.fileExists(atPath: modulemap.path) {
                found.append(modulemap.path)
            }
        }

        return found.sorted()
    }

    /// A digest of the whole configuration, so any knob change invalidates the cache.
    static func configurationSalt(_ configuration: Configuration) -> String {
        CheckerFingerprint.canonicalSalt(configuration) ?? ""
    }

    /// Paths of the built module's artefacts, whichever SwiftPM layout produced them.
    static func builtModuleFiles(searchPath: String, moduleName: String) -> [String] {
        let base = URL(fileURLWithPath: searchPath)
        let manager = FileManager.default
        var found: [String] = []
        for directory in [base, base.appendingPathComponent("Modules", isDirectory: true)] {
            for suffix in ["swiftmodule", "swiftinterface", "swiftdoc"] {
                let candidate = directory.appendingPathComponent("\(moduleName).\(suffix)")
                // SAFETY: CLI tool hashes the project's own built module as a cache input
                if manager.fileExists(atPath: candidate.path) {
                    found.append(candidate.path)
                }
            }
        }
        return found
    }

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
    ///   per article — fences *found* reported separately from fences *checked*, because a
    ///   gate that under-reports its own coverage is indistinguishable from one that passes.
    public func check(projectRoot: URL, configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now

        let catalogues = ArticleDiscovery.catalogues(projectRoot: projectRoot, configuration: configuration)
        guard !catalogues.isEmpty else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No .docc catalogue found; nothing to compile.",
                        ruleId: "doc-code-skip")
                ],
                duration: ContinuousClock.now - start)
        }

        var diagnostics: [Diagnostic] = []
        var audited = 0
        var totalExempt = 0

        for catalogue in catalogues {
            // Without the module every article fails with `no such module` — a wall of
            // findings about this checker's own environment, indistinguishable at a glance
            // from findings about the documentation. `resolve` says what actually happened.
            let environment = DocCatalogueEnvironment.resolve(
                projectRoot: projectRoot, catalogue: catalogue,
                configuration: configuration, checkerId: id)
            diagnostics += environment.notes
            guard let options = environment.options else { continue }

            let verdicts = await audit(catalogue.articles, options: options)
            audited += verdicts.count
            for verdict in verdicts {
                totalExempt += verdict.fencesExempt
                diagnostics += Self.diagnostics(for: verdict)
            }
        }

        if let ceiling = configuration.docCode.exemptionCeiling, totalExempt > ceiling {
            diagnostics.append(
                Diagnostic(
                    severity: .warning,
                    message: """
                        \(totalExempt) blocks are marked <!-- docs:illustrative -->, above the \
                        configured ceiling of \(ceiling). Every exemption is a hypothesis about \
                        the document; a cluster of them sharing one construct is usually a fact \
                        about the tool instead.
                        """,
                    ruleId: "doc-code.exemptions"))
        }

        let failed = diagnostics.contains { $0.severity == .error }
        Self.logger.info("doc-code audited \(audited, privacy: .public) articles")

        // Nothing was compiled, so there is nothing to pass. Reporting `.passed` here would
        // be the worst available answer: a green check that means only that the module was
        // never built.
        let status: CheckResult.Status = failed ? .failed : (audited == 0 ? .skipped : .passed)

        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - start)
    }

    /// Audits articles concurrently, bounded by the machine's processor count.
    ///
    /// Sorted by path afterwards rather than gathered in order: completion order is a
    /// property of the machine, and a report whose findings move between runs is one nobody
    /// can diff.
    private func audit(_ articles: [URL], options: DocCodeAuditOptions) async -> [ArticleVerdict] {
        let sendableOptions = options
        let verdicts = await BoundedConcurrency.map(articles) {
            Self.auditSafely($0, options: sendableOptions)
        }
        return verdicts.sorted { $0.articlePath < $1.articlePath }
    }

    /// Audits one article, turning an unreadable file into a dropped article rather than a
    /// failed run — the rest of the catalogue is still worth checking.
    private static func auditSafely(_ article: URL, options: DocCodeAuditOptions) -> ArticleVerdict? {
        do {
            return try ArticleAuditor.audit(article: article, options: options)
        } catch {
            logger.warning("Could not audit \(article.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Reporting

    /// Turns one article's verdict into diagnostics.
    ///
    /// Errors are grouped by root cause rather than listed one per site. One article
    /// reported 63 errors and had five root causes, one of which — a single missing setup
    /// block defining `q1` — accounted for 52 of them. The raw count ranked it as the third
    /// worst article in the catalogue when it was about an hour's work, and the headline is
    /// what people plan from.
    static func diagnostics(for verdict: ArticleVerdict) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let path = verdict.articlePath

        // Coverage first, and always — pass or fail. Derived from the verdict rather
        // than restated from its fields, so a barriered article cannot report the
        // fences it handed to an aborted compile as fences it checked.
        diagnostics.append(
            Diagnostic(
                severity: .note,
                message: verdict.coverage.summary,
                filePath: path,
                ruleId: "doc-code.coverage"))

        if let barrier = verdict.barrier {
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        Compilation stopped at a barrier: \(barrier). Every error behind it is \
                        invisible, so this article's error count means nothing until the \
                        barrier is resolved.
                        """,
                    filePath: path,
                    ruleId: "doc-code.barrier",
                    suggestedFix: """
                        Resolve the import rather than exempting past it. An exemption at a \
                        barrier does not hide one block — it hides everything behind it.
                        """))
        }

        for collision in verdict.collisions {
            let sites = collision.articleLines.map(String.init).joined(separator: ", ")
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        '\(collision.name)' is declared \(collision.articleLines.count)× at file \
                        scope (\(collision.kind), lines \(sites)). The article is one program, so \
                        these are the same binding.
                        """,
                    filePath: path,
                    lineNumber: collision.articleLines.first,
                    ruleId: "doc-code.collision",
                    suggestedFix: """
                        Rename all but the first — take the suffix from the nearest enclosing \
                        heading, and check the candidate against the module's own symbols. Do \
                        not mark the block illustrative; a name reused for two different things \
                        confuses a reader too.
                        """))
        }

        diagnostics += compileDiagnostics(for: verdict)
        return diagnostics
    }

    /// Compile errors, with `cannot find X in scope` clustered by symbol.
    static func compileDiagnostics(for verdict: ArticleVerdict) -> [Diagnostic] {
        let path = verdict.articlePath
        var undefined: [String: [Int]] = [:]
        var others: [ArticleVerdict.CompileError] = []

        for error in verdict.compileErrors {
            if let symbol = Self.undefinedSymbol(in: error.message) {
                undefined[symbol, default: []].append(error.articleLine)
            } else {
                others.append(error)
            }
        }

        var diagnostics: [Diagnostic] = []
        for (symbol, lines) in undefined.sorted(by: { $0.value.count > $1.value.count }) {
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        Nothing in this article defines '\(symbol)' — \(lines.count) \
                        site\(lines.count == 1 ? "" : "s").
                        """,
                    filePath: path,
                    lineNumber: lines.min(),
                    ruleId: "doc-code.undefined-symbol",
                    suggestedFix: """
                        Add the setup block that defines it, or repoint the reference. Do not \
                        satisfy it with the nearest type-compatible symbol already in scope: \
                        that compiles and prints a wrong number.
                        """))
        }

        for error in others {
            // Downstream noise once a root symbol is unresolved — every instance measured so
            // far has been a shadow of an undefined statement rather than a defect of its own.
            if !undefined.isEmpty, error.message.contains("could not be inferred") { continue }
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: error.message,
                    filePath: path,
                    lineNumber: error.articleLine,
                    ruleId: "doc-code.compile-error",
                    suggestedFix: """
                        Fix the code, or mark the block <!-- docs:illustrative --> if it is \
                        genuinely a fragment rather than an example.
                        """))
        }

        return diagnostics
    }

    /// The symbol named by a `cannot find 'X' in scope` diagnostic.
    static func undefinedSymbol(in message: String) -> String? {
        guard message.hasPrefix("cannot find ") else { return nil }
        guard let open = message.firstIndex(of: "'") else { return nil }
        let rest = message[message.index(after: open)...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[rest.startIndex..<close])
    }
}
