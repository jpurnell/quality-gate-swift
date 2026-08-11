import Foundation
import Testing
@testable import DocCodeAuditor
import QualityGateCore

/// Rung 2: the article does not merely typecheck, it *runs*.
///
/// Every fixture here corresponds to something rung 1 structurally cannot see. An article
/// that force-unwraps `nil`, indexes past the end of an array, or calls a closure declared
/// two hundred lines further down all typecheck perfectly and all die on contact with a
/// CPU. Measured against one 73-article catalogue, three articles typechecked and did not
/// run — one of them the flagship worked example of its own guide.
///
/// The tests split in two. The pure ones need no toolchain and pin the reduction: how an
/// exit status becomes a verdict, how two runs become a determinism report, what the
/// diagnostics say. The fixtures below them compile, link and execute real programs.
@Suite("Article Run")
struct ArticleRunTests {

    // MARK: - Termination, reduced

    @Test("A clean exit is the only success")
    func cleanExitIsSuccess() {
        #expect(RunOutcome.Termination.exited(0).isSuccess)
        #expect(!RunOutcome.Termination.exited(1).isSuccess)
        #expect(!RunOutcome.Termination.signalled(11).isSuccess)
        #expect(!RunOutcome.Termination.timedOut.isSuccess)
        #expect(!RunOutcome.Termination.buildFailed("could not link").isSuccess)
    }

    @Test("A signal is named, not left as a number")
    func signalsAreNamed() {
        // `139` in a CI log is a number nobody looks up. `SIGSEGV` is a sentence.
        #expect(RunOutcome.Termination.signalled(11).summary.contains("SIGSEGV"))
        #expect(RunOutcome.Termination.signalled(5).summary.contains("SIGTRAP"))
        #expect(RunOutcome.Termination.signalled(4).summary.contains("SIGILL"))
        #expect(RunOutcome.Termination.signalled(6).summary.contains("SIGABRT"))
        // An unknown signal still reports its number rather than disappearing.
        #expect(RunOutcome.Termination.signalled(99).summary.contains("99"))
    }

    // MARK: - Determinism

    @Test("Two identical runs are deterministic")
    func identicalRunsAreDeterministic() {
        let report = DeterminismReport.comparing("a\nb\nc\n", "a\nb\nc\n")
        #expect(report.isDeterministic)
        #expect(report.differingLines == 0)
        #expect(report.totalLines == 3)
    }

    @Test("Differing lines are counted, not merely detected")
    func differingLinesAreCounted() {
        // The report has to carry a magnitude. "228 of 232 lines differ" says the article is
        // unseeded; "1 of 232" says one clock reading leaked in, which is a different repair.
        let report = DeterminismReport.comparing("a\nb\nc\nd\n", "a\nX\nc\nY\n")
        #expect(!report.isDeterministic)
        #expect(report.differingLines == 2)
        #expect(report.totalLines == 4)
    }

    @Test("Two runs of different lengths are not deterministic")
    func differingLengthsAreNotDeterministic() {
        let report = DeterminismReport.comparing("a\nb\n", "a\nb\nc\n")
        #expect(!report.isDeterministic)
        #expect(report.differingLines == 1)
        #expect(report.totalLines == 3)
    }

    // MARK: - Linking a `Testing` block

    @Test("An article importing Testing is recognised as needing the testing runtime")
    func testingImportIsDetected() {
        // Rung 1 solved this at the typecheck step with `-F` and `-plugin-path`. Rung 2
        // reintroduces it at the *link* step: the same block typechecks and then dies with
        // `Library not loaded: @rpath/Testing.framework`. If this returns false the gate is
        // about to manufacture an exemption for a construct it simply could not launch.
        #expect(ArticleRunner.importsTesting("import Foundation\nimport Testing\n@Test func f() {}"))
        #expect(ArticleRunner.importsTesting("  import  Testing  "))
        #expect(!ArticleRunner.importsTesting("import Foundation\nlet testing = 1"))
        #expect(!ArticleRunner.importsTesting("// import Testing"))
    }

    // MARK: - Reporting

    @Test("A timeout is reported as a timeout, never as a pass")
    func timeoutIsItsOwnFinding() {
        let verdict = RunVerdict(
            articlePath: "/x/A.md",
            outcome: RunOutcome(termination: .timedOut, standardOutput: "", standardError: ""),
            determinism: nil)
        #expect(!verdict.passed)
        let diagnostics = DocRunAuditor.diagnostics(for: verdict)
        #expect(diagnostics.contains { $0.ruleId == "doc-run.timeout" && $0.severity == .error })
    }

    @Test("A non-deterministic article is an error, not a silent skip")
    func nondeterminismIsAnError() throws {
        // A checker that quietly passes the probabilistic articles certifies the opposite of
        // what it measures — and those are exactly the articles that most need pinned output.
        let verdict = RunVerdict(
            articlePath: "/x/MonteCarlo.md",
            outcome: RunOutcome(termination: .exited(0), standardOutput: "", standardError: ""),
            determinism: DeterminismReport(differingLines: 228, totalLines: 232))
        #expect(!verdict.passed)
        let diagnostics = DocRunAuditor.diagnostics(for: verdict)
        let finding = try #require(diagnostics.first { $0.ruleId == "doc-run.nondeterministic" })
        #expect(finding.severity == .error)
        #expect(finding.message.contains("228"))
        #expect(finding.message.contains("232"))
    }

    @Test("A clean deterministic run produces no error")
    func cleanRunIsClean() {
        let verdict = RunVerdict(
            articlePath: "/x/A.md",
            outcome: RunOutcome(termination: .exited(0), standardOutput: "hi\n", standardError: ""),
            determinism: DeterminismReport(differingLines: 0, totalLines: 1))
        #expect(verdict.passed)
        #expect(!DocRunAuditor.diagnostics(for: verdict).contains { $0.severity == .error })
    }

    @Test("An article that cannot be built is not reported as a run failure")
    func buildFailureIsItsOwnRule() {
        // Rung 1's job. Reporting it as a *run* failure would double-count every article
        // that already fails to compile, and bury the three that compile and die.
        let verdict = RunVerdict(
            articlePath: "/x/A.md",
            outcome: RunOutcome(
                termination: .buildFailed("no such module 'X'"), standardOutput: "", standardError: ""),
            determinism: nil)
        let diagnostics = DocRunAuditor.diagnostics(for: verdict)
        #expect(diagnostics.contains { $0.ruleId == "doc-run.build-failed" })
        #expect(!diagnostics.contains { $0.ruleId == "doc-run.crash" })
    }
}

// MARK: - Fixtures

/// End-to-end: real markdown, real `swiftc`, a real process with a real exit status.
///
/// These link against the standard library and Foundation only, so they need no built
/// module — what is under test is the runner, not any package's documentation.
@Suite("Doc Run Fixtures", .serialized)
struct DocRunFixtureTests {

    private func run(
        _ markdown: String,
        named name: String = "Fixture.md",
        timeout: Duration = .seconds(30),
        verifiesDeterminism: Bool = false
    ) throws -> RunVerdict {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doc-run-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let article = directory.appendingPathComponent(name)
        try markdown.write(to: article, atomically: true, encoding: .utf8)

        var audit = DocCodeAuditOptions()
        audit.imports = ["Foundation"]
        audit.languageFlags = ["-swift-version", "6"]

        var options = DocRunOptions(audit: audit)
        options.timeout = timeout
        options.verifiesDeterminism = verifiesDeterminism
        return try ArticleRunner.run(article: article, options: options)
    }

    // MARK: - Must fail

    @Test("An article that force-unwraps nil fails at run time, having typechecked")
    func forceUnwrapTraps() throws {
        // The real 4.2-ScenarioAnalysisGuide defect: `drivers["Revenue"]!` on a dictionary
        // that does not carry the key. It is the flagship example of its own guide.
        let verdict = try run("""
        # Scenarios

        ```swift
        let drivers: [String: Double] = ["Cost": 1.0]
        let revenue = drivers["Revenue"]!
        print(revenue)
        ```
        """)
        #expect(!verdict.passed)
        if case .signalled = verdict.outcome.termination {} else {
            Issue.record("expected a signal, got \(verdict.outcome.termination)")
        }
    }

    @Test("An article that indexes past the end fails at run time")
    func outOfRangeTraps() throws {
        let verdict = try run("""
        ```swift
        let quarters = [1.0, 2.0]
        print(quarters[5])
        ```
        """)
        #expect(!verdict.passed)
    }

    @Test("An article that loops forever is killed and reported as a timeout")
    func infiniteLoopTimesOut() throws {
        // Never as a pass. A hang is the one failure a runner introduces that the typechecker
        // could not, and the timeout is what bounds it.
        let verdict = try run("""
        ```swift
        var spin = 0
        while true { spin &+= 1 }
        print(spin)
        ```
        """, timeout: .seconds(3))
        #expect(verdict.outcome.termination == .timedOut)
        #expect(!verdict.passed)
    }

    @Test("An article that exits non-zero fails, and its status is reported")
    func nonZeroExitFails() throws {
        let verdict = try run("""
        ```swift
        print("about to give up")
        exit(3)
        ```
        """)
        #expect(verdict.outcome.termination == .exited(3))
        #expect(!verdict.passed)
    }

    // MARK: - Must pass

    @Test("An article that prints nothing passes")
    func silentArticlePasses() throws {
        let verdict = try run("""
        ```swift
        let unread = 41 + 1
        _ = unread
        ```
        """)
        #expect(verdict.passed)
        #expect(verdict.outcome.standardOutput.isEmpty)
    }

    @Test("An article that writes to stderr and exits cleanly passes")
    func stderrIsNotFailure() throws {
        // 1.3-TimeValueOfMoney prints deliberate error text from a `catch` block. A naive
        // "stderr means failure" rule flags a working article for demonstrating error
        // handling, which is the behaviour the article exists to document.
        let verdict = try run("""
        ```swift
        struct RateError: Error {}
        do {
            throw RateError()
        } catch {
            FileHandle.standardError.write(Data("rate out of range\\n".utf8))
        }
        print("continued")
        ```
        """)
        #expect(verdict.passed)
        #expect(verdict.outcome.standardError.contains("rate out of range"))
        #expect(verdict.outcome.standardOutput.contains("continued"))
    }

    @Test("An article whose later blocks consume earlier bindings runs as one program")
    func continuationRuns() throws {
        let verdict = try run("""
        ```swift
        let revenue = [100.0, 120.0, 115.0]
        ```

        Then:

        ```swift
        let total = revenue.reduce(0, +)
        print(total)
        ```
        """)
        #expect(verdict.passed)
        #expect(verdict.outcome.standardOutput.contains("335"))
    }

    // MARK: - Must not flag

    @Test("An article whose only Swift is a @Test block links and runs")
    func testingBlockRuns() throws {
        // If this fails with `Library not loaded: @rpath/Testing.framework`, the rpath is
        // missing and the gate is one step from marking a legitimate construct illustrative.
        let verdict = try run("""
        # Verifying

        ```swift
        import Testing

        @Test func meanIsCorrect() {
            #expect([1.0, 2.0, 3.0].reduce(0, +) / 3 == 2.0)
        }
        ```
        """)
        #expect(verdict.passed, "\(verdict.outcome.termination): \(verdict.outcome.standardError)")
    }

    // MARK: - Locale

    @Test("Number formatting does not depend on the gate machine's preferences")
    func localeIsPinned() throws {
        // Measured: the same program prints `2,000` under en_US and `2.000` under de_DE, and
        // on macOS `LANG` does not move Foundation's locale. Without pinning, rung 3 is a
        // check on System Settings.
        let verdict = try run("""
        ```swift
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        print(formatter.string(from: 2000) ?? "")
        ```
        """)
        #expect(verdict.passed)
        #expect(verdict.outcome.standardOutput.contains("2,000"))
    }

    // MARK: - Determinism

    @Test("A seeded article is reported deterministic")
    func seededArticleIsDeterministic() throws {
        let verdict = try run("""
        ```swift
        var state: UInt64 = 42
        for _ in 0..<5 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            print(state % 1000)
        }
        ```
        """, verifiesDeterminism: true)
        #expect(verdict.passed)
        #expect(verdict.determinism?.isDeterministic == true)
    }

    @Test("An unseeded article is reported, not skipped")
    func unseededArticleIsReported() throws {
        let verdict = try run("""
        ```swift
        for _ in 0..<20 { print(Double.random(in: 0...1)) }
        ```
        """, verifiesDeterminism: true)
        #expect(verdict.outcome.termination == .exited(0))
        #expect(verdict.determinism?.isDeterministic == false)
        #expect(!verdict.passed)
    }

    // MARK: - Negative control

    @Test("Known-good and known-bad input produce different run verdicts")
    func negativeControl() throws {
        let good = try run("```swift\nlet a = [1.0]\nprint(a[0])\n```", named: "Good.md")
        let bad = try run("```swift\nlet a = [1.0]\nprint(a[7])\n```", named: "Bad.md")
        #expect(good.passed)
        #expect(!bad.passed)
    }
}
