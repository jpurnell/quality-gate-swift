import Foundation
import Testing
@testable import QualityGateCore

/// `RunTally` is the one place the counts and the verdict are computed, so the number
/// printed after "warning(s)" and the number `--strict` gates on are the same stored value.
@Suite("RunTally")
struct RunTallyTests {

    private static let statuses: [CheckResult.Status] = [.passed, .warning, .failed, .skipped]
    private static let severities: [Diagnostic.Severity?] = [nil, .note, .warning, .error]

    /// Every {status} × {no diagnostic, note, warning, error} result — 16 of them.
    private static let everyResult: [CheckResult] = statuses.flatMap { status in
        severities.map { severity in
            CheckResult(
                checkerId: "\(status.rawValue)-\(severity?.rawValue ?? "none")",
                status: status,
                diagnostics: severity.map { [Diagnostic(severity: $0, message: "finding", ruleId: "rule")] } ?? [],
                duration: .zero)
        }
    }

    /// Every run of one, two or three of those results: 16 + 256 + 4096.
    private static let everyRun: [[CheckResult]] = {
        let singles = everyResult.map { [$0] }
        let pairs = everyResult.flatMap { first in everyResult.map { [first, $0] } }
        let triples = pairs.flatMap { pair in everyResult.map { pair + [$0] } }
        return singles + pairs + triples
    }()

    private func warning(_ ruleId: String = "rule") -> Diagnostic {
        Diagnostic(severity: .warning, message: "finding", ruleId: ruleId)
    }

    @Test("the invariant: --strict fails on warnings exactly when the printed count is non-zero")
    func strictGatesOnThePrintedCount() {
        // The test that would have caught HRBLE, and it does not name a checker. Whatever
        // status each checker chose, a run that prints `N warning(s)` with N > 0 and has no
        // failed checker is failed by --strict, and by nothing else.
        #expect(Self.everyRun.count == 4368)
        var disagreements: [String] = []
        for run in Self.everyRun {
            let tally = RunTally(run)
            let countSaysGate = tally.warnings > 0 && tally.failedCheckers.isEmpty
            let verdictSaysGate = tally.verdict(strict: true, truncated: false) == .failedByStrictWarnings
            if countSaysGate != verdictSaysGate {
                disagreements.append(run.map(\.checkerId).joined(separator: " + "))
            }
        }
        #expect(disagreements == [])
    }

    @Test("the printed count is the count of warning diagnostics, whoever emitted them")
    func warningsIsTheDiagnosticCount() {
        var disagreements: [String] = []
        for run in Self.everyRun {
            // Reconciliation may add one `gate.status-without-finding` per result; nothing
            // else changes the number.
            let expected = run.map { $0.reconciled().warningCount }.reduce(0, +)
            if RunTally(run).warnings != expected {
                disagreements.append(run.map(\.checkerId).joined(separator: " + "))
            }
        }
        #expect(disagreements == [])
    }

    @Test("without --strict, warnings never fail the run")
    func lenientPassesOnWarnings() {
        let results = [
            CheckResult(checkerId: "recursion", status: .passed, diagnostics: [warning()], duration: .zero),
            CheckResult(checkerId: "build", status: .warning, diagnostics: [warning()], duration: .zero),
        ]
        let tally = RunTally(results)
        #expect(tally.warnings == 2)
        #expect(tally.errors == 0)
        #expect(tally.verdict(strict: false, truncated: false) == .passed)
        #expect(tally.verdict(strict: true, truncated: false) == .failedByStrictWarnings)
        for run in Self.everyRun {
            #expect(RunTally(run).verdict(strict: false, truncated: false) != .failedByStrictWarnings)
        }
    }

    @Test("a truncated run in which nothing failed is incomplete, strict or not")
    func truncatedWithNothingFailedIsIncomplete() {
        let clean = [
            CheckResult(checkerId: "build", status: .passed, diagnostics: [], duration: .zero)
        ]
        #expect(RunTally(clean).verdict(strict: false, truncated: true) == .incomplete)
        #expect(RunTally(clean).verdict(strict: true, truncated: true) == .incomplete)
        #expect(RunTally([]).verdict(strict: true, truncated: true) == .incomplete)
    }

    @Test("a truncated run that failed is failed, not incomplete")
    func truncatedAndFailedIsFailed() {
        let failed = [
            CheckResult(
                checkerId: "safety", status: .failed,
                diagnostics: [Diagnostic(severity: .error, message: "x", ruleId: "r")], duration: .zero)
        ]
        #expect(RunTally(failed).verdict(strict: false, truncated: true) == .failed)
        // Under --strict the runner stops *at* a warning. That run did fail; INCOMPLETE is
        // the verdict for "nothing failed, but not everything ran", which is not this.
        let warned = [
            CheckResult(checkerId: "xcode-build", status: .warning, diagnostics: [warning()], duration: .zero)
        ]
        #expect(RunTally(warned).verdict(strict: true, truncated: true) == .failedByStrictWarnings)
        #expect(RunTally(warned).verdict(strict: false, truncated: true) == .incomplete)
    }

    @Test("a failed checker outranks strict warnings")
    func failedOutranksStrictWarnings() {
        let results = [
            CheckResult(checkerId: "recursion", status: .passed, diagnostics: [warning()], duration: .zero),
            CheckResult(
                checkerId: "safety", status: .failed,
                diagnostics: [Diagnostic(severity: .error, message: "x", ruleId: "r")], duration: .zero),
        ]
        let tally = RunTally(results)
        #expect(tally.verdict(strict: true, truncated: false) == .failed)
        #expect(tally.failedCheckers == ["safety"])
        #expect(tally.warnedCheckers == ["recursion"])
        #expect(tally.errors == 1)
        #expect(tally.warnings == 1)
    }

    @Test("the tally reconciles what it is given, so a caller cannot hand it a stale status")
    func tallyReconciles() {
        let unreconciled = [
            CheckResult(checkerId: "recursion", status: .passed, diagnostics: [warning()], duration: .zero),
            CheckResult(checkerId: "build", status: .passed, diagnostics: [], duration: .zero),
            CheckResult(checkerId: "doc-code", status: .skipped, diagnostics: [], duration: .zero),
        ]
        let tally = RunTally(unreconciled)
        #expect(tally.warnedCheckers == ["recursion"])
        #expect(tally.passedCheckers == ["build"])
        #expect(tally.skippedCheckers == ["doc-code"])
        #expect(tally.failedCheckers == [])
    }

    @Test("a skipped checker's warning is counted, and gates under --strict")
    func skippedWarningIsCountedAndGates() {
        // The test pinned to `RunTally.countsWarningsOnSkippedResults` — the one decision
        // point for this question. Turning that off changes this test and nothing else.
        //
        // `doc-code` skips with a `module-unavailable` warning that says "this is not a
        // pass". Its status stays skipped; the warning is printed and counted, and the
        // number --strict reads is the number printed. The consequence is that
        // `--strict --check doc-code` on a cold `.build` fails.
        #expect(RunTally.countsWarningsOnSkippedResults)
        let results = [
            CheckResult(
                checkerId: "doc-code", status: .skipped,
                diagnostics: [warning("doc-code.module-unavailable")], duration: .zero)
        ]
        let tally = RunTally(results)
        #expect(tally.warnings == 1)
        #expect(tally.warnedCheckers == [])
        #expect(tally.skippedCheckers == ["doc-code"])
        #expect(tally.verdict(strict: true, truncated: false) == .failedByStrictWarnings)
        #expect(tally.verdict(strict: false, truncated: false) == .passed)
    }

    @Test("an empty run passes when it was not truncated")
    func emptyRunPasses() {
        let tally = RunTally([])
        #expect(tally.errors == 0)
        #expect(tally.warnings == 0)
        #expect(tally.verdict(strict: true, truncated: false) == .passed)
    }
}
