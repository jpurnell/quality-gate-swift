import Foundation
import Testing
@testable import QualityGateCore

/// A configuration override that hides or lowers a finding leaves a record of it.
///
/// `overrides: { rule: off }` used to return `nil` from a `compactMap`: the finding was gone
/// and nothing in any output format said it had existed. HRVKit ran for months with
/// `concurrency.task-captures-self-no-isolation: info` over 21 findings, nine of them real
/// ordering defects, and printed the summary of a repository with none.
@Suite("OverrideProcessor records what it hides")
struct OverrideProcessorRecordingTests {

    private func finding(
        _ ruleId: String, severity: Diagnostic.Severity = .warning, file: String = "/repo/Sources/A.swift",
        line: Int = 10
    ) -> Diagnostic {
        Diagnostic(severity: severity, message: "m", filePath: file, lineNumber: line, ruleId: ruleId)
    }

    private func result(_ diagnostics: [Diagnostic], overrides: [DiagnosticOverride] = []) -> CheckResult {
        CheckResult(
            checkerId: "concurrency", status: .failed, diagnostics: diagnostics, overrides: overrides,
            complianceRecords: [], duration: .zero)
    }

    @Test("`off` removes the finding and records it, with the finding's own location")
    func offIsRecorded() {
        let processor = OverrideProcessor(overrides: ["concurrency.task-captures-self-no-isolation": .off])
        let processed = processor.apply(to: result([
            finding("concurrency.task-captures-self-no-isolation", line: 88),
            finding("concurrency.task-captures-self-no-isolation", line: 131),
            finding("concurrency.other", line: 5),
        ]))

        #expect(processed.diagnostics.map(\.ruleId) == ["concurrency.other"])
        let records = processed.overrides.map(SuppressionRecord.init)
        #expect(records.count == 2)
        #expect(records.map(\.kind) == [.suppressed, .suppressed])
        #expect(records.map(\.form) == ["config overrides: off", "config overrides: off"])
        #expect(records.map(\.lineNumber) == [88, 131])
        #expect(records[0].filePath == "/repo/Sources/A.swift")
        #expect(records[0].ruleId == "concurrency.task-captures-self-no-isolation")
        #expect(records[0].reason == "overrides: concurrency.task-captures-self-no-isolation: off")
        #expect(records[0].markerLine == nil)
    }

    @Test("A wildcard `off` records the key that was written, not the rule it matched")
    func wildcardNamesItsKey() {
        let processor = OverrideProcessor(overrides: ["safety.*": .off])
        let processed = processor.apply(to: result([finding("safety.force-unwrap", severity: .error)]))
        let records = processed.overrides.map(SuppressionRecord.init)

        #expect(records.count == 1)
        #expect(records[0].ruleId == "safety.force-unwrap")
        #expect(records[0].reason == "overrides: safety.*: off")
    }

    @Test("`info` keeps the finding as a note and records the downgrade")
    func infoIsRecorded() {
        let processor = OverrideProcessor(overrides: ["concurrency.x": .info])
        let processed = processor.apply(to: result([finding("concurrency.x", severity: .warning)]))

        #expect(processed.diagnostics.map(\.severity) == [.note])
        let records = processed.overrides.map(SuppressionRecord.init)
        #expect(records.map(\.form) == ["config overrides: info"])
        #expect(records[0].reason == "overrides: concurrency.x: info (was warning)")
    }

    @Test("`warning` on an error is a downgrade and is recorded")
    func warningOnErrorIsRecorded() {
        let processor = OverrideProcessor(overrides: ["concurrency.x": .warning])
        let processed = processor.apply(to: result([finding("concurrency.x", severity: .error)]))

        #expect(processed.diagnostics.map(\.severity) == [.warning])
        #expect(processed.overrides.map(SuppressionRecord.init).map(\.form) == ["config overrides: warning"])
    }

    @Test("An escalation is not a suppression and records nothing")
    func escalationIsNotRecorded() {
        let processor = OverrideProcessor(overrides: ["concurrency.x": .error, "concurrency.y": .warning])
        let processed = processor.apply(to: result([
            finding("concurrency.x", severity: .warning),
            finding("concurrency.y", severity: .note),
            finding("concurrency.y", severity: .warning),
        ]))

        #expect(processed.diagnostics.map(\.severity) == [.error, .warning, .warning])
        #expect(processed.overrides.isEmpty)
    }

    @Test("`info` on what is already a note records nothing")
    func infoOnNoteIsNotRecorded() {
        let processor = OverrideProcessor(overrides: ["concurrency.x": .info])
        let processed = processor.apply(to: result([finding("concurrency.x", severity: .note)]))
        #expect(processed.overrides.isEmpty)
    }

    @Test("A vendor-path demotion is recorded, naming the vendor path")
    func vendorDemotionIsRecorded() {
        let processor = OverrideProcessor(overrides: [:], vendorPaths: ["ThirdParty"])
        let processed = processor.apply(to: result([
            finding("safety.force-unwrap", severity: .error, file: "/repo/ThirdParty/lib/X.swift", line: 7),
            finding("safety.force-unwrap", severity: .error, file: "/repo/Sources/X.swift", line: 7),
            finding("safety.coverage", severity: .note, file: "/repo/ThirdParty/lib/X.swift", line: 1),
        ]))

        #expect(processed.diagnostics.map(\.severity) == [.note, .error, .note])
        let records = processed.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].form == "config vendorPaths")
        #expect(records[0].reason == "vendorPaths: ThirdParty (was error)")
        #expect(records[0].filePath == "/repo/ThirdParty/lib/X.swift")
        #expect(records[0].lineNumber == 7)
    }

    @Test("Records the checker made are kept, ahead of the configuration's")
    func checkerRecordsAreKept() {
        let marker = DiagnosticOverride.inlineMarker(
            form: "// SAFETY:", ruleId: "safety.force-unwrap", filePath: "/repo/Sources/A.swift",
            findingLine: 3, markerLine: 3, comment: "x! // SAFETY: fine")
        let processor = OverrideProcessor(overrides: ["concurrency.x": .off])
        let processed = processor.apply(to: result([finding("concurrency.x")], overrides: [marker]))

        #expect(processed.overrides.count == 2)
        #expect(processed.overrides[0] == marker)
    }

    @Test("Compliance records survive the processor")
    func complianceRecordsSurvive() {
        let compliance = ComplianceRecord(
            ruleId: "pointer-escape", annotation: "Allowed by configuration: memcpy",
            filePath: "/repo/Sources/A.swift", lineNumber: 4)
        let original = CheckResult(
            checkerId: "pointer-escape", status: .failed, diagnostics: [finding("pointer.x")],
            overrides: [], complianceRecords: [compliance], duration: .zero)
        let processed = OverrideProcessor(overrides: ["pointer.x": .off]).apply(to: original)

        #expect(processed.complianceRecords == [compliance])
    }

    @Test("Applying the processor twice does not record a hidden finding twice")
    func applyingTwiceIsStable() {
        let processor = OverrideProcessor(overrides: ["concurrency.x": .info])
        let once = processor.apply(to: result([finding("concurrency.x", severity: .warning)]))
        let twice = processor.apply(to: once)
        #expect(twice.overrides.count == 1)
    }
}
