import Foundation
import Testing
@testable import QualityGateCore

/// `CheckResult.reconciled()` makes status a function of the diagnostics wherever the
/// diagnostics say more than the status does. It only ever raises.
@Suite("CheckResult reconciliation")
struct CheckResultReconciliationTests {

    private func diagnostic(_ severity: Diagnostic.Severity, _ ruleId: String = "rule") -> Diagnostic {
        Diagnostic(severity: severity, message: "finding", ruleId: ruleId)
    }

    private func result(_ status: CheckResult.Status, _ diagnostics: [Diagnostic]) -> CheckResult {
        CheckResult(checkerId: "checker", status: status, diagnostics: diagnostics, duration: .zero)
    }

    @Test("a passed result carrying a warning becomes a warning")
    func passedWithWarningBecomesWarning() {
        let reconciled = result(.passed, [diagnostic(.warning)]).reconciled()
        #expect(reconciled.status == .warning)
        #expect(reconciled.diagnostics == [diagnostic(.warning)])
    }

    // MARK: - The error rows

    @Test("a passed result carrying an error becomes failed")
    func passedWithErrorBecomesFailed() {
        // "1 error(s)" above "✅ PASSED" is the same disagreement as a counted warning that
        // does not gate, and this is the one row that changes a non-strict exit code.
        let reconciled = result(.passed, [diagnostic(.error)]).reconciled()
        #expect(reconciled.status == .failed)
        #expect(reconciled.diagnostics == [diagnostic(.error)])
        #expect(reconciled.failsRun(strict: false))
    }

    @Test("a warning result carrying an error becomes failed")
    func warningWithErrorBecomesFailed() {
        #expect(result(.warning, [diagnostic(.error)]).reconciled().status == .failed)
        #expect(result(.warning, [diagnostic(.warning), diagnostic(.error)]).reconciled().status == .failed)
        // No finding is synthesized: the error is the finding.
        #expect(result(.warning, [diagnostic(.error)]).reconciled().diagnostics == [diagnostic(.error)])
    }

    @Test("a skipped result carrying an error stays skipped")
    func skippedWithErrorStaysSkipped() {
        let original = result(.skipped, [diagnostic(.error)])
        #expect(original.reconciled() == original)
    }

    @Test("a passed result carrying only notes is unchanged")
    func passedWithNotesIsUnchanged() {
        let original = result(.passed, [diagnostic(.note), diagnostic(.note, "other")])
        #expect(original.reconciled() == original)
    }

    @Test("a passed result with no diagnostics is unchanged")
    func cleanPassIsUnchanged() {
        let original = result(.passed, [])
        #expect(original.reconciled() == original)
    }

    @Test("a skipped result is unchanged, whatever it carries")
    func skippedIsUnchanged() {
        // A skipped checker examined nothing; its status says so and stays said.
        let withWarning = result(.skipped, [diagnostic(.warning)])
        #expect(withWarning.reconciled() == withWarning)
        let withNote = result(.skipped, [diagnostic(.note)])
        #expect(withNote.reconciled() == withNote)
    }

    @Test("a failed result is never lowered")
    func failedIsNeverLowered() {
        let bare = result(.failed, [])
        #expect(bare.reconciled() == bare)
        // `safety` fails on warnings without --strict. That is its policy; reconciliation
        // does not loosen it.
        let onWarnings = result(.failed, [diagnostic(.warning)])
        #expect(onWarnings.reconciled() == onWarnings)
    }

    @Test("a warning status with no warning finding gains one, attributed to the gate")
    func warningWithoutFindingIsMadeVisible() {
        let reconciled = result(.warning, [diagnostic(.note)]).reconciled()
        #expect(reconciled.status == .warning)
        let synthesized = reconciled.diagnostics.filter { $0.ruleId == "gate.status-without-finding" }
        #expect(synthesized.count == 1)
        #expect(synthesized.first?.severity == .warning)
        #expect(synthesized.first?.message == "[checker] reported WARNING without a warning-severity finding")
        // The checker's own diagnostics survive, in order, ahead of the gate's.
        #expect(reconciled.diagnostics.first == diagnostic(.note))
        #expect(reconciled.diagnostics.count == 2)
        #expect(reconciled.warningCount == 1)
    }

    @Test("a warning status with a warning finding is unchanged")
    func warningWithFindingIsUnchanged() {
        let original = result(.warning, [diagnostic(.warning)])
        #expect(original.reconciled() == original)
    }

    @Test("reconciliation is idempotent")
    func reconciliationIsIdempotent() {
        let statuses: [CheckResult.Status] = [.passed, .warning, .failed, .skipped]
        let diagnosticSets: [[Diagnostic]] = [
            [], [diagnostic(.note)], [diagnostic(.warning)], [diagnostic(.error)],
            [diagnostic(.warning), diagnostic(.error)],
        ]
        for status in statuses {
            for diagnostics in diagnosticSets {
                let once = result(status, diagnostics).reconciled()
                #expect(once.reconciled() == once, "\(status) with \(diagnostics.map(\.severity))")
            }
        }
    }

    @Test("reconciliation preserves everything that is not status or diagnostics")
    func reconciliationPreservesTheRest() {
        let original = CheckResult(
            checkerId: "recursion", status: .passed, diagnostics: [diagnostic(.warning)],
            duration: .milliseconds(250))
        let reconciled = original.reconciled()
        #expect(reconciled.checkerId == "recursion")
        #expect(reconciled.duration == .milliseconds(250))
        #expect(reconciled.overrides == original.overrides)
        #expect(reconciled.complianceRecords == original.complianceRecords)
    }

    @Test("failsRun is the one per-result predicate")
    func failsRunPredicate() {
        #expect(result(.failed, []).failsRun(strict: false))
        #expect(result(.failed, []).failsRun(strict: true))
        #expect(!result(.warning, [diagnostic(.warning)]).failsRun(strict: false))
        #expect(result(.warning, [diagnostic(.warning)]).failsRun(strict: true))
        #expect(!result(.passed, []).failsRun(strict: true))
        #expect(!result(.skipped, []).failsRun(strict: true))
    }
}
