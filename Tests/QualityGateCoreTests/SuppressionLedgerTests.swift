import Foundation
import Testing
@testable import QualityGateCore

/// The totals a run prints about what it was told not to raise.
@Suite("SuppressionLedger")
struct SuppressionLedgerTests {

    private static let longReason = "the cache directory may not exist yet and a miss is the ordinary case"

    private func silent(_ reason: String, file: String = "/repo/A.swift", line: Int) -> DiagnosticOverride {
        .inlineMarker(
            form: "// silent:", ruleId: "logging.silent-try", filePath: file,
            findingLine: line, markerLine: line, comment: "try? f() // silent: \(reason)")
    }

    private func result(
        _ checkerId: String, overrides: [DiagnosticOverride] = [], diagnostics: [Diagnostic] = [],
        status: CheckResult.Status = .passed
    ) -> CheckResult {
        CheckResult(
            checkerId: checkerId, status: status, diagnostics: diagnostics, overrides: overrides,
            duration: .zero)
    }

    // MARK: - Totals

    @Test("Totals separate acknowledged from suppressed, per checker and overall, by form")
    func totalsPerCheckerAndOverall() {
        let logging = result("logging", overrides: [
            silent("best effort", line: 3),
            silent(Self.longReason, line: 9),
        ])
        let safety = result("safety", overrides: [
            .inlineMarker(
                form: "// SAFETY:", ruleId: "safety.force-unwrap", filePath: "/repo/B.swift",
                findingLine: 4, markerLine: 4, comment: "x! // SAFETY: fine"),
            .inlineMarker(
                form: "// SECURITY:", ruleId: "security.ssrf", filePath: "/repo/B.swift",
                findingLine: 8, markerLine: 7, comment: "// SECURITY: pinned",
                validatedBy: "security-acknowledgement"),
        ])
        let ledger = SuppressionLedger(results: [logging, safety, result("recursion")])

        #expect(ledger.overall.acknowledged == 2)
        #expect(ledger.overall.suppressed == 2)
        #expect(ledger.overall.baselined == 0)
        #expect(ledger.overall.suppressedByForm == ["// silent:": 1, "// SAFETY:": 1])
        #expect(ledger.overall.acknowledgedByForm == ["// silent:": 1, "// SECURITY:": 1])

        #expect(ledger.checkers.map(\.checkerId) == ["logging", "safety", "recursion"])
        #expect(ledger.checkers[0].totals.acknowledged == 1)
        #expect(ledger.checkers[0].totals.suppressed == 1)
        #expect(ledger.checkers[1].totals.acknowledged == 1)
        #expect(ledger.checkers[1].totals.suppressed == 1)
        #expect(ledger.checkers[2].totals == SuppressionTotals())
        #expect(ledger.checkers[2].records.isEmpty)
    }

    @Test("A configuration record counts every finding it hid, not one")
    func hiddenCountIsSummed() {
        let record = SuppressionRecord(
            kind: .suppressed, form: "config excludePatterns", validator: nil,
            rejection: "configuration carries no validated reason", ruleId: "*", filePath: nil,
            lineNumber: nil, markerLine: nil, reason: "x", hidden: 21)
        let ledger = SuppressionLedger(results: [result("concurrency", overrides: [record.asOverride])])

        #expect(ledger.overall.suppressed == 21)
        #expect(ledger.overall.suppressedByForm == ["config excludePatterns": 21])
    }

    @Test("Baselined debts are counted from the notes the ledger left, per checker")
    func baselinedCount() {
        let debt = Diagnostic(
            severity: .note, message: "x (baselined until 2027-01-01)", filePath: "/repo/A.swift",
            lineNumber: 1, ruleId: "fp-division-unguarded", origin: BaselineLedger.origin)
        let expired = Diagnostic(
            severity: .warning, message: "x — baseline EXPIRED", filePath: "/repo/A.swift",
            lineNumber: 2, ruleId: "fp-division-unguarded", origin: BaselineLedger.origin)
        let plain = Diagnostic(severity: .note, message: "coverage", ruleId: "fp-safety.coverage")
        let ledger = SuppressionLedger(results: [
            result("fp-safety", diagnostics: [debt, debt, expired, plain], status: .warning)
        ])

        #expect(ledger.checkers[0].totals.baselined == 2)
        #expect(ledger.overall.baselined == 2)
    }

    // MARK: - Per-file duplicates

    @Test("The same reason on a second marker in one file is a suppression; the first stands")
    func duplicateReasonInOneFile() {
        let ledger = SuppressionLedger(results: [result("logging", overrides: [
            silent(Self.longReason, line: 3),
            silent(Self.longReason, line: 30),
        ])])
        let records = ledger.checkers[0].records

        #expect(records[0].kind == .acknowledged)
        #expect(records[1].kind == .suppressed)
        #expect(records[1].rejection == "repeats the reason on line 3 of this file")
        #expect(ledger.overall.acknowledged == 1)
        #expect(ledger.overall.suppressed == 1)
    }

    @Test("The same reason in two files is two acknowledgements")
    func sameReasonInTwoFiles() {
        let ledger = SuppressionLedger(results: [result("logging", overrides: [
            silent(Self.longReason, file: "/repo/A.swift", line: 3),
            silent(Self.longReason, file: "/repo/B.swift", line: 3),
        ])])
        #expect(ledger.overall.acknowledged == 2)
        #expect(ledger.overall.suppressed == 0)
    }

    @Test("One marker that silences two findings is not a duplicate of itself")
    func oneMarkerTwoFindings() {
        let first = DiagnosticOverride.inlineMarker(
            form: "// silent:", ruleId: "logging.silent-try", filePath: "/repo/A.swift",
            findingLine: 3, markerLine: 2, comment: "// silent: \(Self.longReason)")
        let second = DiagnosticOverride.inlineMarker(
            form: "// silent:", ruleId: "logging.silent-try", filePath: "/repo/A.swift",
            findingLine: 2, markerLine: 2, comment: "// silent: \(Self.longReason)")
        let ledger = SuppressionLedger(results: [result("logging", overrides: [first, second])])
        #expect(ledger.overall.acknowledged == 2)
    }

    @Test("A reason a checker validated itself is not re-judged for duplicates")
    func checkerValidatedDuplicatesAreNotDemoted() {
        func security(_ line: Int) -> DiagnosticOverride {
            .inlineMarker(
                form: "// SECURITY:", ruleId: "security.ssrf", filePath: "/repo/B.swift",
                findingLine: line, markerLine: line - 1, comment: "// SECURITY: \(Self.longReason)",
                validatedBy: "security-acknowledgement")
        }
        let ledger = SuppressionLedger(results: [result("safety", overrides: [security(5), security(50)])])
        #expect(ledger.overall.acknowledged == 2)
    }

    // MARK: - Exclusions

    @Test("Active exclusions are carried, and are not added to the finding totals")
    func exclusionsAreSeparate() {
        let exclusion = ActiveExclusion(
            form: "excludePatterns", entries: ["**/Fixtures/**"], matchedFiles: 14,
            detail: "1 pattern matched 14 .swift file(s); they were not audited")
        let ledger = SuppressionLedger(results: [result("logging")], exclusions: [exclusion])

        #expect(ledger.exclusions == [exclusion])
        #expect(ledger.overall.suppressed == 0)
    }

    // MARK: - The ratchet

    @Test("Under the default policy a suppression changes nothing about the result")
    func defaultPolicyAddsNothing() {
        let original = result("logging", overrides: [silent("best effort", line: 3)])
        let applied = SuppressionRatchet.apply(to: original, policy: .note)
        #expect(applied == original)
    }

    @Test("Under `warn` each suppression is a warning at the marker; acknowledgements are not")
    func warnPolicy() {
        let original = result("logging", overrides: [
            silent("best effort", line: 3),
            silent(Self.longReason, line: 9),
        ])
        let applied = SuppressionRatchet.apply(to: original, policy: .warn)

        #expect(applied.diagnostics.count == 1)
        #expect(applied.diagnostics[0].severity == .warning)
        #expect(applied.diagnostics[0].ruleId == "gate.unvalidated-suppression")
        #expect(applied.diagnostics[0].filePath == "/repo/A.swift")
        #expect(applied.diagnostics[0].lineNumber == 3)
        #expect(applied.diagnostics[0].message
            == "`// silent:` silences logging.silent-try without a validated reason (2 words, 8 required): \"best effort\"")
        #expect(applied.status == .warning)
        #expect(applied.overrides == original.overrides)
    }

    @Test("Under `error` a suppression fails the checker")
    func errorPolicy() {
        let applied = SuppressionRatchet.apply(
            to: result("logging", overrides: [silent("", line: 3)]), policy: .error)
        #expect(applied.diagnostics.count == 1)
        #expect(applied.diagnostics[0].severity == .error)
        #expect(applied.status == .failed)
        #expect(applied.diagnostics[0].message
            == "`// silent:` silences logging.silent-try without a validated reason (no reason given)")
    }

    @Test("The ratchet sees a per-file duplicate the record alone cannot")
    func ratchetSeesDuplicates() {
        let applied = SuppressionRatchet.apply(
            to: result("logging", overrides: [
                silent(Self.longReason, line: 3),
                silent(Self.longReason, line: 30),
            ]), policy: .warn)
        #expect(applied.diagnostics.count == 1)
        #expect(applied.diagnostics[0].lineNumber == 30)
    }

    @Test("The ratchet is idempotent, so a result that passes through it twice warns once")
    func ratchetIsIdempotent() {
        let once = SuppressionRatchet.apply(
            to: result("logging", overrides: [silent("best effort", line: 3)]), policy: .warn)
        let twice = SuppressionRatchet.apply(to: once, policy: .warn)
        #expect(twice.diagnostics.count == 1)
    }

    @Test("A skipped result keeps its status under the ratchet")
    func skippedStaysSkipped() {
        let applied = SuppressionRatchet.apply(
            to: result("logging", overrides: [silent("x", line: 3)], status: .skipped), policy: .error)
        #expect(applied.status == .skipped)
    }

    // MARK: - Policy decoding

    @Test("The policy reads note, warn, warning and error, and refuses anything else")
    func policyDecoding() throws {
        #expect(try Configuration.from(yaml: "suppressions: note").suppressions == .note)
        #expect(try Configuration.from(yaml: "suppressions: warn").suppressions == .warn)
        #expect(try Configuration.from(yaml: "suppressions: warning").suppressions == .warn)
        #expect(try Configuration.from(yaml: "suppressions: error").suppressions == .error)
        #expect(try Configuration.from(yaml: "excludePatterns: []").suppressions == .note)
        #expect(throws: QualityGateError.self) {
            _ = try Configuration.from(yaml: "suppressions: loud")
        }
    }

    @Test("`suppressions` is a key the schema knows")
    func policyKeyIsKnown() throws {
        #expect(try Configuration.from(yaml: "suppressions: warn").unknownKeys == nil)
    }
}
