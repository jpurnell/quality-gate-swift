import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// Checks that the numbers a DocC article publishes are the numbers its code produces.
///
/// Rung 3 of the documentation verification ladder. Rung 1 asks whether the code compiles,
/// rung 2 whether it runs; this asks whether the article is telling the truth about what it
/// computed. Two defects found by hand on a five-figure sample of one catalogue:
/// `[100, 120, 115]` published for a value that is `[0.1, 0.12, 0.115]`, and `$1,043.30`
/// published for a bond that prices at `$1,043.76` — where the stale figure turned out to be
/// exactly the *annual*-coupon price, so it came from a calculation that ignored the payment
/// frequency. Both articles pass rungs 1 and 2.
///
/// ## No `--fix`, ever
///
/// Not deferred as it is for `doc-code` — **prohibited**. An autofixer that rewrites a
/// documented number to match the program is a machine for laundering regressions into
/// documentation: it can never fail, and it never means anything. The pressure when this
/// checker is red at 5pm is precisely to edit the comment until it goes green, and a tool
/// that automates that pressure is worse than no tool.
///
/// ## What this cannot catch, in the order it is most likely to be mistaken for coverage
///
/// - **A number that is wrong in the code and correctly transcribed into the documentation.**
///   The largest hole, and structural: documentation written *from* a program's output cannot
///   be checked *against* that program's output. Only differential tests against published
///   references close this class.
/// - **Cross-block object identity.** An article that declares `result` eight times and reads
///   it from six blocks produces numbers; they are the wrong object's numbers. This rung
///   makes that worse, not better — it turns "compiles, silently wrong" into "compiles, runs,
///   has a green assertion, silently wrong."
/// - **Prose claims.** 28 of 99 in the measured corpus. `// Result: Approaches but never
///   exceeds 25,000` is true, useful, and beyond any comparator.
/// - **A trap on a path the run does not take**, and **machine-dependent output** — a timing
///   article will correctly refuse to be verified, which puts a whole genre out of scope.
///
/// ## It is a change detector, not a truth detector
///
/// When an accuracy fix moves five expectations, this rung turns every affected documented
/// figure red, and the repair is to edit the documentation. That is the correct outcome — and
/// it means the red state looks identical whether the change was an improvement or a
/// regression. It enforces "the published numbers are the numbers the code produces", and not
/// one inch more.
public struct DocClaimsAuditor: QualityChecker, Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DocClaimsAuditor")

    /// Unique identifier for this checker.
    public let id = "doc-claims"

    /// Human-readable name for this checker.
    public let name = "Documentation Output Claims"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Figures a DocC article publishes must match what that article's own program computes (opt-in)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.documentation

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.documentation

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Safe to run in the concurrent group; every article is instrumented and executed in
    /// its own temporary directory.
    public var isParallelSafe: Bool { true }

    /// Hermetic, on the same terms as `doc-run` and for the same reason: an article whose two
    /// runs disagree is reported as blocked rather than trusted, so the verdict is a function
    /// of the tree.
    public var hermeticity: Hermeticity { .hermetic }

    /// Creates a new auditor.
    public init() {}

    /// Inputs whose change could change the verdict — the same set the other rungs read.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        DocCodeAuditor.cacheInputs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration)
    }

    /// Runs the check against the current directory.
    public func check(configuration: Configuration) async throws -> CheckResult {
        try await check(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration)
    }

    /// Runs the check against a given project root.
    ///
    /// Only articles that carry claims are instrumented. A claim is the unit of work, and an
    /// article with none has nothing for this rung to say about it — running it would report
    /// coverage the checker does not have.
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
                        message: "No .docc catalogue found; nothing to verify.",
                        ruleId: "doc-claims-skip")
                ],
                duration: ContinuousClock.now - start)
        }

        var diagnostics: [Diagnostic] = []
        var verdicts: [ClaimsVerdict] = []

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
            // Never optional here. A claim about an unseeded program's output is not a claim
            // this checker can hold anyone to, and the two-run comparison is the only thing
            // that establishes which articles those are.
            options.verifiesDeterminism = true

            let carrying = Self.articlesCarryingClaims(catalogue.articles, imports: audit.imports)
            verdicts += await Self.verifyAll(carrying, options: options)
        }

        for verdict in verdicts {
            diagnostics += Self.diagnostics(for: verdict)
        }
        diagnostics.append(Self.summary(of: verdicts))

        let failed = diagnostics.contains { $0.severity == .error }
        Self.logger.info("doc-claims verified \(verdicts.count, privacy: .public) articles")

        let status: CheckResult.Status = failed ? .failed : (verdicts.isEmpty ? .skipped : .passed)
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - start)
    }

    /// The articles that make at least one claim.
    ///
    /// A cheap parse, and it is what keeps this rung from being rung 2 again: 57 of one
    /// catalogue's 73 articles carry no claim at all, so instrumenting them would cost the
    /// build and report nothing.
    static func articlesCarryingClaims(_ articles: [URL], imports: [String]) -> [URL] {
        articles.filter { article in
            // silent: an unreadable article carries no claim this rung can verify, and doc-code already reports the file it could not read
            guard let text = try? String(contentsOf: article, encoding: .utf8) else { return false }
            return !ArticleAssembler.assemble(text, imports: imports).claims.isEmpty
        }
    }

    /// Verifies articles concurrently, bounded by the machine's processor count.
    static func verifyAll(_ articles: [URL], options: DocRunOptions) async -> [ClaimsVerdict] {
        let sendableOptions = options
        let verdicts = await BoundedConcurrency.map(articles) {
            verifySafely($0, options: sendableOptions)
        }
        return verdicts.sorted { $0.articlePath < $1.articlePath }
    }

    private static func verifySafely(_ article: URL, options: DocRunOptions) -> ClaimsVerdict? {
        do {
            return try ClaimVerifier.verify(article: article, options: options)
        } catch {
            logger.warning("Could not verify \(article.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Reporting

    /// Claims found against claims checked, across the catalogue.
    ///
    /// Always emitted. The gap between the two numbers is the part of this report that is
    /// easy to leave out and expensive to lose: a gate that under-reports its own coverage is
    /// indistinguishable from a gate that passes.
    static func summary(of verdicts: [ClaimsVerdict]) -> Diagnostic {
        let found = verdicts.reduce(0) { $0 + $1.found }
        let checked = verdicts.reduce(0) { $0 + $1.checked }
        let mismatched = verdicts.reduce(0) { $0 + $1.mismatches.count }
        let unanchored = verdicts.reduce(0) { $0 + $1.unanchored.count }
        let notComparable = verdicts.reduce(0) { $0 + $1.notComparable.count }
        let exempt = verdicts.reduce(0) { $0 + $1.exempt.count }
        let unstable = verdicts.reduce(0) { $0 + $1.nondeterministic.count }
        let blocked = verdicts.filter { $0.blocked != nil }.count

        return Diagnostic(
            severity: .note,
            message: """
                \(verdicts.count) articles carry \(found) output claims: \(checked) checked, \
                \(mismatched) do not hold, \(notComparable) not comparable, \
                \(unanchored) unanchored, \(unstable) not reproducible, \
                \(exempt) in exempt blocks. \
                \(blocked) articles could not be measured at all.
                """,
            ruleId: "doc-claims.coverage")
    }

    /// Turns one article's verdict into diagnostics.
    static func diagnostics(for verdict: ClaimsVerdict) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        let path = verdict.articlePath

        if let blocked = verdict.blocked {
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        No claim in this article could be verified: \(blocked). It makes \
                        \(verdict.found) documented claims, and none of them is currently a \
                        statement anyone can check.
                        """,
                    filePath: path,
                    ruleId: "doc-claims.blocked",
                    suggestedFix: """
                        Seed every generator the article samples — including hand-rolled loops \
                        over a probabilistic driver, which take no seed and are the ones that \
                        get missed. A single differing line is usually a clock reading rather \
                        than randomness, and needs a fixed date rather than a seed.
                        """))
        }

        if !verdict.nondeterministic.isEmpty {
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        \(verdict.nondeterministic.count) documented value\
                        \(verdict.nondeterministic.count == 1 ? "" : "s") \
                        (line\(verdict.nondeterministic.count == 1 ? "" : "s") \
                        \(list(verdict.nondeterministic))) changed between two runs of the same \
                        binary. A figure the program does not reproduce is not a figure anyone \
                        can be held to, so it is reported rather than compared.
                        """,
                    filePath: path,
                    lineNumber: verdict.nondeterministic.first,
                    ruleId: "doc-claims.nondeterministic",
                    suggestedFix: """
                        Seed the generator this value comes from. Note that a hand-rolled loop \
                        over a probabilistic driver takes no seed even when the API beside it \
                        does, and that iterating a Dictionary or a Set is unordered per process \
                        — both reproduce as "the number moved and nothing else did".
                        """))
        }

        for mismatch in verdict.mismatches {
            diagnostics.append(
                Diagnostic(
                    severity: .error,
                    message: """
                        The documentation says \(mismatch.documented); the code produces \
                        \(mismatch.measured).
                        """,
                    filePath: path,
                    lineNumber: mismatch.articleLine,
                    ruleId: "doc-claims.mismatch",
                    suggestedFix: """
                        Find out which one is wrong before changing either. This checker cannot \
                        tell a numerical improvement from a regression — editing the comment to \
                        match the output is the one repair that always works and sometimes \
                        means nothing.
                        """))
        }

        if !verdict.unanchored.isEmpty || !verdict.notComparable.isEmpty || !verdict.exempt.isEmpty {
            let parts = [
                verdict.notComparable.isEmpty
                    ? nil : "\(verdict.notComparable.count) not comparable (lines \(list(verdict.notComparable)))",
                verdict.unanchored.isEmpty
                    ? nil : "\(verdict.unanchored.count) unanchored (lines \(list(verdict.unanchored)))",
                verdict.exempt.isEmpty
                    ? nil : "\(verdict.exempt.count) in exempt blocks (lines \(list(verdict.exempt)))",
            ].compactMap { $0 }
            diagnostics.append(
                Diagnostic(
                    severity: .note,
                    message: """
                        \(verdict.checked) of \(verdict.found) claims checked; \
                        \(parts.joined(separator: ", ")).
                        """,
                    filePath: path,
                    ruleId: "doc-claims.uncheckable"))
        }

        return diagnostics
    }

    /// A capped list of line numbers, so one article cannot fill a report.
    static func list(_ lines: [Int]) -> String {
        let shown = lines.prefix(8).map(String.init).joined(separator: ", ")
        return lines.count > 8 ? shown + ", …" : shown
    }
}
