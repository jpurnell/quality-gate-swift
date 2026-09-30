import Foundation
import Testing
@testable import QualityGateCore

/// The baseline must be applied *before* the early-exit decision, not after it.
///
/// `CheckerRunner` stops at the first failing result when `continueOnFailure` is off, and it
/// judges the result the `transform` hook returns. Overrides went through that hook; the
/// ledger did not — it ran afterwards, over the finished result set. So in any adopted
/// repository the checker holding baselined debt still *failed during the run* and truncated
/// it, every checker ordered after it never ran, and the ledger then rewrote that checker's
/// verdict to `.passed`. The run reported success over an unexamined majority.
///
/// `adopt` promises a green gate on day one. Until this, it charged the rest of the run for it:
/// without `--continue-on-failure` an adopted repository silently lost every later checker, and
/// with it the exit code reflected a run where a baselined checker had failed — so neither
/// invocation was both complete and correctly-exiting.
@Suite("Baseline applies before the stop decision")
struct BaselineBeforeStopDecisionTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func finding(rule: String, file: String, line: Int) -> Diagnostic {
        Diagnostic(severity: .error, message: "planted", filePath: file, lineNumber: line, ruleId: rule)
    }

    private func sandboxFile(_ lines: [String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Fixture.swift").path
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Records whether its checker was ever asked to run. A class so the stub stays a value.
    // Justification: the single stored `value` is only ever read or written while `lock` is held, so every access is serialised.
    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var didRun: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func mark() { lock.lock(); value = true; lock.unlock() }
    }

    /// A checker whose result is fixed, so the run's shape is the only variable.
    private struct StubChecker: QualityChecker {
        let id: String
        let name: String
        let summary = "Test double; not a documented checker"
        let category = CheckerCategory.specialty
        let kind = CheckerKind.code
        let effect = CheckerEffect.readOnly
        let executesProjectCode = false
        let isParallelSafe = false
        let result: CheckResult
        let ran: Ran

        init(id: String, result: CheckResult, ran: Ran) {
            self.id = id
            self.name = id
            self.result = result
            self.ran = ran
        }

        func check(configuration: Configuration) async throws -> CheckResult {
            ran.mark()
            return result
        }
    }

    // MARK: - The defect

    @Test("A checker whose only findings are baselined does not truncate the run")
    func baselinedCheckerDoesNotTruncate() async throws {
        let file = try sandboxFile(["let a = x!"])
        let planted = finding(rule: "safety.force-unwrap", file: file, line: 1)
        let ledger = BaselineLedger.adopt(findings: [planted], recordedAt: now, decayDays: 180)

        // First checker fails on a finding the ledger covers; second must still run.
        let adopted = StubChecker(
            id: "safety",
            result: CheckResult(checkerId: "safety", status: .failed, diagnostics: [planted], duration: .milliseconds(1)),
            ran: Ran())
        let later = StubChecker(
            id: "complexity",
            result: CheckResult(checkerId: "complexity", status: .passed, diagnostics: [], duration: .milliseconds(1)),
            ran: Ran())

        let outcome = await CheckerRunner().run(
            checkers: [adopted, later],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: false,
            transform: { ledger.applying(to: $0, now: now) })

        #expect(later.ran.didRun, "the run truncated at the baselined checker")
        #expect(outcome.truncation == nil, "a fully-baselined checker must not stop the run")
        #expect(outcome.results.count == 2)
        #expect(outcome.results[0].status == .passed, "its only finding was covered")
    }

    /// The answer to "what does an adopted repository with zero new findings exit with".
    @Test("An adopted repository with zero new findings runs every checker and reports none failing")
    func adoptedRepositoryWithNoNewFindingsIsGreenAndComplete() async throws {
        let file = try sandboxFile(["let a = x!", "let b = y!"])
        let planted = [
            finding(rule: "safety.force-unwrap", file: file, line: 1),
            finding(rule: "safety.force-unwrap", file: file, line: 2),
        ]
        let ledger = BaselineLedger.adopt(findings: planted, recordedAt: now, decayDays: 180)

        let checkers = (0..<4).map { index in
            StubChecker(
                id: "checker-\(index)",
                result: index == 0
                    ? CheckResult(checkerId: "checker-0", status: .failed, diagnostics: planted, duration: .milliseconds(1))
                    : CheckResult(checkerId: "checker-\(index)", status: .passed, diagnostics: [], duration: .milliseconds(1)),
                ran: Ran())
        }

        let outcome = await CheckerRunner().run(
            checkers: checkers,
            configuration: Configuration(),
            strict: false,
            continueOnFailure: false,
            transform: { ledger.applying(to: $0, now: now) })

        // Complete: every checker ran.
        let everyCheckerRan = checkers.allSatisfy(\.ran.didRun)
        #expect(everyCheckerRan, "an adopted repository must not lose the checkers after the adopted one")
        #expect(outcome.truncation == nil)

        // Green: nothing failing, so the caller exits 0.
        let anythingFailing = outcome.results.contains { $0.status == .failed }
        #expect(anythingFailing == false, "zero new findings must not gate")

        // And the counts read back off the transformed results.
        let summary = BaselineLedger.summarise(outcome.results)
        #expect(summary.baselined == 2)
        #expect(summary.newFindings == 0)
        #expect(summary.expired == 0)
    }

    // MARK: - Controls: what must NOT change

    @Test("A genuinely new finding still truncates the run")
    func newFindingStillTruncates() async throws {
        let file = try sandboxFile(["let a = x!"])
        // The ledger covers line 1; the checker reports line 2, which nobody adopted.
        let ledger = BaselineLedger.adopt(
            findings: [finding(rule: "safety.force-unwrap", file: file, line: 1)],
            recordedAt: now, decayDays: 180)
        let uncovered = finding(rule: "safety.force-unwrap", file: file, line: 2)

        let failing = StubChecker(
            id: "safety",
            result: CheckResult(checkerId: "safety", status: .failed, diagnostics: [uncovered], duration: .milliseconds(1)),
            ran: Ran())
        let later = StubChecker(
            id: "complexity",
            result: CheckResult(checkerId: "complexity", status: .passed, diagnostics: [], duration: .milliseconds(1)),
            ran: Ran())

        let outcome = await CheckerRunner().run(
            checkers: [failing, later],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: false,
            transform: { ledger.applying(to: $0, now: now) })

        #expect(later.ran.didRun == false, "a real failure must still stop the run")

        // Not merely "it truncated": name the checker that stopped it and the one that
        // never ran. A `!= nil` here would also pass if the runner stopped at the wrong
        // checker, which is the failure this control exists to catch.
        let truncation = try #require(outcome.truncation)
        #expect(truncation.stoppedAt == "safety")
        #expect(truncation.unreached == ["complexity"])
    }

    @Test("summarise reads back exactly what apply counted")
    func summariseAgreesWithApply() throws {
        // The two paths must not drift: `apply` is now `map(applying:) + summarise`, and this
        // pins that the derived counts equal what the batch call reports.
        let file = try sandboxFile(["let a = x!", "let b = y!", "let c = z!"])
        var ledger = BaselineLedger.adopt(
            findings: [finding(rule: "r", file: file, line: 1)], recordedAt: now, decayDays: 180)
        let expired = BaselineLedger.adopt(
            findings: [finding(rule: "r", file: file, line: 2)],
            recordedAt: now.addingTimeInterval(-40 * 86_400), decayDays: 30)
        ledger = BaselineLedger(records: ledger.records + expired.records)

        let result = CheckResult(
            checkerId: "safety",
            status: .failed,
            diagnostics: [
                finding(rule: "r", file: file, line: 1),
                finding(rule: "r", file: file, line: 2),
                finding(rule: "r", file: file, line: 3),
            ],
            duration: .milliseconds(1))

        let applied = BaselineLedger.apply(ledger: ledger, to: [result], now: now)
        let derived = BaselineLedger.summarise(applied.results)
        #expect(derived == applied.summary)
        #expect(derived.baselined == 1)
        #expect(derived.expired == 1)
        #expect(derived.newFindings == 1)
    }
}
