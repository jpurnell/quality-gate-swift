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

    /// Safe to run in the concurrent group — and that placement is what orders it correctly.
    ///
    /// ``CheckerRunner`` runs every non-parallel-safe checker to completion first, then the
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
    /// answer. The case that might otherwise argue for ``Hermeticity/external`` — a module
    /// that was never built — is handled explicitly as a `.skipped` result carrying its
    /// reason, so the classification does not have to carry it, and a genuine documentation
    /// failure keeps its authority to block the commit.
    public var hermeticity: Hermeticity { .hermetic }

    /// Creates a new auditor.
    public init() {}

    /// Inputs whose change could change the verdict.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        Self.cacheInputs(
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
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
        for subdirectory in ["Sources", "Tests"] {
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

    /// A digest of the whole configuration, so any knob change invalidates the cache.
    static func configurationSalt(_ configuration: Configuration) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return CheckerFingerprint.digest(of: try encoder.encode(configuration))
        } catch {
            logger.warning("Could not encode configuration for the cache salt; forcing a miss: \(error.localizedDescription, privacy: .public)")
            return ""
        }
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
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
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
            guard let searchPath = ArticleDiscovery.moduleSearchPath(
                projectRoot: projectRoot, moduleName: catalogue.moduleName, configuration: configuration
            ) else {
                // Without the module every article fails with `no such module` — a wall of
                // findings about this checker's own environment, indistinguishable at a
                // glance from findings about the documentation. Say what actually happened.
                diagnostics.append(
                    Diagnostic(
                        severity: .note,
                        message: """
                            Skipped \(catalogue.moduleName): no built module found under \
                            .build/debug. Run the build first — this checker compiles \
                            documentation against the module, it does not build it.
                            """,
                        ruleId: "doc-code.module-unavailable"))
                continue
            }

            let mode = ManifestLanguageMode.read(projectRoot: projectRoot, target: catalogue.moduleName)
            if !mode.isDetermined {
                diagnostics.append(
                    Diagnostic(
                        severity: .note,
                        message: "\(catalogue.moduleName): \(mode.explanation)",
                        ruleId: "doc-code.language-mode"))
            }
            if !mode.unrecognisedSettings.isEmpty {
                diagnostics.append(
                    Diagnostic(
                        severity: .note,
                        message: """
                            \(catalogue.moduleName): these swiftSettings were not translated \
                            into compiler flags, so documentation is checked under slightly \
                            different rules than the build: \
                            \(mode.unrecognisedSettings.joined(separator: ", ")).
                            """,
                        ruleId: "doc-code.language-mode"))
            }

            var options = DocCodeAuditOptions()
            options.moduleSearchPath = searchPath
            options.imports = ["Foundation", catalogue.moduleName] + configuration.docCode.extraImports
            options.languageFlags = mode.flags

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
    private func audit(_ articles: [URL], options: DocCodeAuditOptions) async -> [ArticleVerdict] {
        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let sendableOptions = options

        return await withTaskGroup(of: ArticleVerdict?.self) { group in
            var next = 0
            while next < min(limit, articles.count) {
                let article = articles[next]
                group.addTask { Self.auditSafely(article, options: sendableOptions) }
                next += 1
            }

            var results: [ArticleVerdict] = []
            while let verdict = await group.next() {
                if let verdict { results.append(verdict) }
                if next < articles.count {
                    let article = articles[next]
                    group.addTask { Self.auditSafely(article, options: sendableOptions) }
                    next += 1
                }
            }
            return results.sorted { $0.articlePath < $1.articlePath }
        }
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

        // Coverage first, and always — pass or fail.
        diagnostics.append(
            Diagnostic(
                severity: .note,
                message: """
                    \(verdict.fencesFound) Swift fences: \(verdict.fencesChecked) checked, \
                    \(verdict.fencesExempt) exempt.
                    """,
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
