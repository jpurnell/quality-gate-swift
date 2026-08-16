import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// Executes each DocC article as one program, and reports what happened.
///
/// Rung 2 of the documentation verification ladder. `doc-code` asks whether the code a
/// reader would copy *compiles*; this asks whether it *runs*. The gap is not theoretical.
/// Measured against one 73-article catalogue, three articles typechecked cleanly and then:
///
/// - trapped on `drivers["Revenue"]!` — a dictionary key the article never sets, in the
///   flagship worked example of a guide about scenario analysis;
/// - segfaulted at address zero before its first `print`, because top-level globals
///   initialise in source order and the article called a closure declared 180 lines later;
/// - failed to load `Testing.framework`, which is not a documentation defect at all.
///
/// The third is the one to design against. `DocCodeAuditor` already records the lesson —
/// a gate that cannot compile a legitimate construct will be worked around, and the
/// workaround looks exactly like compliance — and rung 2 reintroduces it at the *link* step,
/// where rung 1 had already solved it at the typecheck step. Hence the rpath in
/// `ArticleRunner.linkArguments(imports:searchPaths:source:)`.
///
/// ## Determinism is part of the verdict
///
/// Each article is run twice and its output compared. An unseeded example has no pinned
/// output: rung 3 cannot verify it, and this rung cannot honestly claim to have measured it.
/// A non-deterministic article is therefore an **error**, not a skip — the articles that
/// most need pinned numbers are exactly the probabilistic ones, and a checker that quietly
/// passes them certifies the opposite of what it measures.
///
/// ## Opt-in, and not under `--full`
///
/// Rung 2's precondition is stronger than rung 1's: an article must not merely compile as
/// one program, it must *run* as one, top to bottom, without a trap. That is a second
/// convention, and it is red on arrival for any catalogue that has not adopted it.
public struct DocRunAuditor: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocRunAuditor")

    /// Unique identifier for this checker.
    public let id = "doc-run"

    /// Human-readable name for this checker.
    public let name = "Documentation Code Runner"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "DocC articles must *run* top to bottom without trapping, not merely compile — the article is one program (opt-in)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.documentation

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.documentation

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Safe to run in the concurrent group, and that placement is what orders it correctly.
    ///
    /// `BuildChecker` declares itself non-parallel-safe, so the runner completes it before
    /// starting the concurrent group — which is precisely what guarantees this checker reads
    /// a finished `.build/debug` rather than racing `swift build` writing into it. Each
    /// article is compiled, linked and executed in its own temporary directory, so the
    /// articles themselves are safe to run against one another.
    public var isParallelSafe: Bool { true }

    /// Hermetic — but only because the determinism precheck is what makes it true.
    ///
    /// A checker that runs arbitrary code and reads a clock or a network is not a pure
    /// function of the tree. The two-run comparison is exactly the test of whether it is, and
    /// an article that fails it is reported rather than trusted. Without that precheck this
    /// would have to declare `Hermeticity/temporal`, its findings would clamp to `.note`,
    /// and it could not fail the gate — which would make it decorative.
    ///
    /// Two hazards the precheck does not close, both worth knowing before trusting it: a
    /// seeded GPU run and a seeded CPU run produce different, each-internally-reproducible
    /// streams, so agreement here does not imply agreement on a CI runner; and two runs is a
    /// sample of size two, which passes a 1-in-1000 non-determinism 999 times in 1000.
    public var hermeticity: Hermeticity { .hermetic }

    /// Creates a new auditor.
    public init() {}

    /// Inputs whose change could change the verdict — the same set `doc-code` reads.
    ///
    /// Identical by construction rather than by coincidence: this rung executes the very
    /// program that rung typechecks, so anything that could change one could change the
    /// other. The salt differs because the configuration is encoded whole.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        DocCodeAuditor.cacheInputs(
            projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            configuration: configuration)
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
    ///   - configuration: The gate configuration; the `doc-code` knobs are shared.
    /// - Returns: One diagnostic per finding, plus a summary note counting the articles that
    ///   ran — reported separately from the articles *found*, because a gate that
    ///   under-reports its own coverage is indistinguishable from a gate that passes.
    public func check(projectRoot: URL, configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now

        let catalogues = ArticleDiscovery.catalogues(
            projectRoot: projectRoot, configuration: configuration)
        guard !catalogues.isEmpty else {
            return CheckResult(
                checkerId: id,
                status: .skipped,
                diagnostics: [
                    Diagnostic(
                        severity: .note,
                        message: "No .docc catalogue found; nothing to run.",
                        ruleId: "doc-run-skip")
                ],
                duration: ContinuousClock.now - start)
        }

        var diagnostics: [Diagnostic] = []
        var verdicts: [RunVerdict] = []

        for catalogue in catalogues {
            let environment = DocCatalogueEnvironment.resolve(
                projectRoot: projectRoot, catalogue: catalogue,
                configuration: configuration, checkerId: id)
            diagnostics += environment.notes
            guard let audit = environment.options else { continue }

            var options = DocRunOptions(audit: audit)
            options.librarySearchPaths = configuration.docCode.librarySearchPaths
            options.timeout = .seconds(configuration.docCode.runTimeoutSeconds)
            options.locale = configuration.docCode.runLocale
            options.verifiesDeterminism = configuration.docCode.verifiesDeterminism

            verdicts += await Self.runAll(catalogue.articles, options: options)
        }

        for verdict in verdicts {
            diagnostics += Self.diagnostics(for: verdict)
        }
        diagnostics.append(Self.summary(of: verdicts))

        let failed = diagnostics.contains { $0.severity == .error }
        Self.logger.info("doc-run executed \(verdicts.count, privacy: .public) articles")

        // Nothing ran, so there is nothing to pass. `.passed` here would mean only that the
        // module was never built.
        let status: CheckResult.Status = failed ? .failed : (verdicts.isEmpty ? .skipped : .passed)
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - start)
    }

    /// Runs articles concurrently, bounded by the machine's processor count.
    static func runAll(_ articles: [URL], options: DocRunOptions) async -> [RunVerdict] {
        let sendableOptions = options
        let verdicts = await BoundedConcurrency.map(articles) {
            runSafely($0, options: sendableOptions)
        }
        return verdicts.sorted { $0.articlePath < $1.articlePath }
    }

    /// Runs one article, turning an unreadable file into a dropped article rather than a
    /// failed run — the rest of the catalogue is still worth executing.
    private static func runSafely(_ article: URL, options: DocRunOptions) -> RunVerdict? {
        do {
            return try ArticleRunner.run(article: article, options: options)
        } catch {
            logger.warning("Could not run \(article.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Reporting

    /// How many articles ran, how many did not, and why not.
    ///
    /// Always emitted, pass or fail. The count that matters is not "articles checked" but
    /// "articles that reached the CPU": an article held back by a compile error was never
    /// measured by this rung at all, and folding those into a pass would report coverage
    /// this checker does not have.
    static func summary(of verdicts: [RunVerdict]) -> Diagnostic {
        let ran = verdicts.filter { verdict in
            if case .buildFailed = verdict.outcome.termination { return false }
            return true
        }
        let clean = ran.filter { $0.outcome.termination.isSuccess }
        let nondeterministic = clean.filter { $0.determinism?.isDeterministic == false }
        return Diagnostic(
            severity: .note,
            message: """
                \(verdicts.count) articles: \(ran.count) ran, \
                \(verdicts.count - ran.count) could not be built, \
                \(clean.count - nondeterministic.count) ran cleanly and reproducibly, \
                \(nondeterministic.count) produced different output on a second run.
                """,
            ruleId: "doc-run.coverage")
    }

    /// Turns one article's run into diagnostics.
    ///
    /// One finding per article at most, plus determinism. An article that dies produces one
    /// death; listing every consequence of it would rank the article by the length of its
    /// stack rather than by the size of its repair.
    static func diagnostics(for verdict: RunVerdict) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let path = verdict.articlePath

        switch verdict.outcome.termination {
        case .buildFailed(let reason):
            // Rung 1's finding, reported here as a note so the coverage arithmetic is
            // honest without double-counting a compile error as a run failure.
            diagnostics.append(
                Diagnostic(
                    severity: .note,
                    message: """
                        Not run: the article does not build (\(reason)). Nothing on this rung \
                        is a statement about it until doc-code is green.
                        """,
                    filePath: path,
                    ruleId: "doc-run.build-failed"))

        case .timedOut:
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        The article was still running at the deadline and was killed. A hang \
                        is the one failure a runner introduces that the typechecker could not, \
                        and it is never a pass.
                        """,
                    filePath: path,
                    ruleId: "doc-run.timeout",
                    suggestedFix: """
                        Find the unbounded loop or the blocking wait. If the example is \
                        legitimately long-running, it is not an example — narrow it, or mark \
                        the block <!-- docs:illustrative --> and say why in the prose.
                        """))

        case .signalled(let signal):
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        The article compiles and then dies: \
                        \(RunOutcome.Termination.signalled(signal).summary).\
                        \(Self.evidence(verdict))
                        """,
                    filePath: path,
                    ruleId: "doc-run.crash",
                    suggestedFix: """
                        Read the last line of output to find how far it got. A force-unwrap of \
                        a key the article never sets and a call to a global closure declared \
                        further down the page both look like this, and both are real defects \
                        in code a reader is invited to copy.
                        """))

        case .exited(let status) where status != 0:
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        The article compiles and then exits \(status).\(Self.evidence(verdict))
                        """,
                    filePath: path,
                    ruleId: "doc-run.exit",
                    suggestedFix: """
                        A worked example that ends in a non-zero status is telling the reader \
                        it failed. Fix the code, or make the failure the point of the example \
                        and say so in the prose.
                        """))

        case .exited:
            break
        }

        if let determinism = verdict.determinism, !determinism.isDeterministic {
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        Not deterministic: \(determinism.differingLines) of \
                        \(determinism.totalLines) output lines differ between two runs of the \
                        same binary\
                        \(determinism.differingValues > 0 ? ", and \(determinism.differingValues) measured values differ" : ""). \
                        No documented output in this article can be verified until its \
                        randomness is seeded.
                        """,
                    filePath: path,
                    ruleId: "doc-run.nondeterministic",
                    suggestedFix: """
                        Seed every generator the article samples, not only the ones with an \
                        obvious `seed:` parameter — a hand-rolled loop over a probabilistic \
                        driver takes no seed and is easy to miss. A clock reading is the other \
                        common cause, and it usually differs on exactly one line.
                        """))
        }

        return diagnostics
    }

    /// The last line of output, when there is one, so a reader can see how far it got.
    static func evidence(_ verdict: RunVerdict) -> String {
        let lastOut = verdict.outcome.standardOutput.lines.last { !$0.isEmpty }
        let firstErr = verdict.outcome.standardError.lines.first { !$0.isEmpty }
        var parts: [String] = []
        if let firstErr { parts.append("stderr: \(firstErr)") }
        if let lastOut {
            parts.append("last stdout line: \(lastOut)")
        } else {
            parts.append("it printed nothing at all")
        }
        return " " + parts.joined(separator: "; ") + "."
    }
}
