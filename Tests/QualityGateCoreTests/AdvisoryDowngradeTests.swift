import Foundation
import Testing
@testable import QualityGateCore

/// Phase 4 §3 — trial mode (`--advisory-all`).
///
/// The whole gate as a survey: every error/warning downgraded to a note,
/// every failing verdict to passed, exit 0 — while the findings themselves
/// stay fully visible. One honest transform, applied after checkers run and
/// before reporting, so reporters and telemetry see the downgraded truth
/// consistently.
@Suite("AdvisoryDowngrade")
struct AdvisoryDowngradeTests {

    private func makeResult(
        checkerId: String,
        status: CheckResult.Status,
        severities: [Diagnostic.Severity]
    ) -> CheckResult {
        CheckResult(
            checkerId: checkerId,
            status: status,
            diagnostics: severities.enumerated().map { index, severity in
                Diagnostic(
                    severity: severity,
                    message: "finding \(index)",
                    filePath: "Sources/Fixture.swift",
                    lineNumber: index + 1,
                    ruleId: "fixture.rule-\(index)")
            },
            duration: .milliseconds(5))
    }

    @Test("errors and warnings downgrade to notes; messages and rules survive")
    func downgradesSeverities() {
        let downgraded = AdvisoryDowngrade.apply(to: [
            makeResult(checkerId: "safety", status: .failed,
                       severities: [.error, .warning, .note]),
        ])
        let diagnostics = downgraded[0].diagnostics
        #expect(diagnostics.map(\.severity) == [.note, .note, .note])
        #expect(diagnostics.map(\.message) == ["finding 0", "finding 1", "finding 2"])
        #expect(diagnostics[0].ruleId == "fixture.rule-0")
        #expect(diagnostics[0].filePath == "Sources/Fixture.swift")
        #expect(diagnostics[0].lineNumber == 1)
    }

    @Test("failed and warning verdicts become passed; skipped stays skipped")
    func downgradesStatuses() {
        let downgraded = AdvisoryDowngrade.apply(to: [
            makeResult(checkerId: "safety", status: .failed, severities: [.error]),
            makeResult(checkerId: "recursion", status: .warning, severities: [.warning]),
            makeResult(checkerId: "build", status: .passed, severities: []),
            makeResult(checkerId: "xcode-build", status: .skipped, severities: []),
        ])
        #expect(downgraded.map(\.status) == [.passed, .passed, .passed, .skipped])
        #expect(downgraded[0].diagnostics.count == 1)
    }

    @Test("checker ids, durations, ordering, and overrides are preserved")
    func preservesStructure() {
        let results = [
            makeResult(checkerId: "safety", status: .failed, severities: [.error]),
            makeResult(checkerId: "recursion", status: .warning, severities: [.warning]),
        ]
        let downgraded = AdvisoryDowngrade.apply(to: results)
        #expect(downgraded.map(\.checkerId) == ["safety", "recursion"])
        #expect(downgraded.map(\.duration) == results.map(\.duration))
        #expect(downgraded.map(\.overrides.count) == results.map(\.overrides.count))
        #expect(downgraded.map(\.complianceRecords.count) == results.map(\.complianceRecords.count))
    }

    @Test("an empty result set is an empty result set")
    func emptyIsEmpty() {
        #expect(AdvisoryDowngrade.apply(to: []).isEmpty)
    }

    @Test("provenance survives the downgrade (plugin findings keep their origin)")
    func originSurvives() {
        let result = CheckResult(
            checkerId: "vigil",
            status: .failed,
            diagnostics: [Diagnostic(
                severity: .error, message: "planted",
                ruleId: "fixture.rule", origin: "plugin/fixture")],
            duration: .milliseconds(1))
        let downgraded = AdvisoryDowngrade.apply(to: [result])
        #expect(downgraded[0].diagnostics[0].severity == .note)
        #expect(downgraded[0].diagnostics[0].origin == "plugin/fixture")
    }
}
