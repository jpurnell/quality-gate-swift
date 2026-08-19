import Foundation
import Testing
@testable import QualityGateCore

/// The hermeticity contract: a checker may **fail** the gate only on facts
/// derivable from the working tree at the commit under test.
///
/// Findings that depend on wall-clock time (`.temporal`) or on network /
/// out-of-tree state (`.external`) still surface — as notes — but never block.
/// Unreachable external state resolves to `.skipped` with a reason, never to a
/// pass (a lie) and never to a failure (a lie in the other direction).
@Suite("Hermeticity contract")
struct HermeticityTests {

    // MARK: - Fixtures

    /// A checker whose result and hermeticity are both dictated by the test.
    private struct StubChecker: QualityChecker {
        let id: String
        let name = "Stub"
        let summary = "Test double; not a documented checker"
        let category = CheckerCategory.specialty
        let kind = CheckerKind.code
        let effect = CheckerEffect.readOnly
        let executesProjectCode = false
        let hermeticity: Hermeticity
        let result: CheckResult

        func check(configuration: Configuration) async throws -> CheckResult { result }
    }

    /// A checker that always throws — stands in for unreachable external state.
    private struct ThrowingChecker: QualityChecker {
        let id = "throwing"
        let name = "Throwing"
        let summary = "Test double; not a documented checker"
        let category = CheckerCategory.specialty
        let kind = CheckerKind.code
        let effect = CheckerEffect.readOnly
        let executesProjectCode = false
        let hermeticity: Hermeticity

        func check(configuration: Configuration) async throws -> CheckResult {
            throw QualityGateError.configurationError("network unreachable")
        }
    }

    private static func result(
        id: String = "stub",
        status: CheckResult.Status,
        severities: [Diagnostic.Severity]
    ) -> CheckResult {
        CheckResult(
            checkerId: id,
            status: status,
            diagnostics: severities.enumerated().map { index, severity in
                Diagnostic(
                    severity: severity,
                    message: "finding \(index)",
                    filePath: "/tmp/File.swift",
                    lineNumber: index + 1,
                    ruleId: "stub.rule-\(index)"
                )
            },
            duration: .zero
        )
    }

    // MARK: - Declaration

    @Test("Checkers are hermetic unless they opt out")
    func defaultsToHermetic() {
        let checker = StubChecker(
            id: "d", hermeticity: .hermetic,
            result: Self.result(status: .passed, severities: []))
        // The default lives on the protocol extension; a checker that never
        // mentions hermeticity must still gate normally.
        #expect(DefaultingChecker().hermeticity == .hermetic)
        #expect(checker.hermeticity == .hermetic)
    }

    private struct DefaultingChecker: QualityChecker {
        let id = "defaulting"
        let name = "Defaulting"
        let summary = "Test double; not a documented checker"
        let category = CheckerCategory.specialty
        let kind = CheckerKind.code
        let effect = CheckerEffect.readOnly
        let executesProjectCode = false
        func check(configuration: Configuration) async throws -> CheckResult {
            CheckResult(checkerId: id, status: .passed, diagnostics: [], duration: .zero)
        }
    }

    // MARK: - Clamp

    @Test("Hermetic results pass through untouched")
    func hermeticUntouched() {
        let input = Self.result(status: .failed, severities: [.error, .warning, .note])
        let clamped = HermeticityClamp.apply(to: input, hermeticity: .hermetic)
        #expect(clamped == input)
    }

    @Test("Temporal findings clamp to notes and stop failing")
    func temporalClamped() {
        let input = Self.result(status: .failed, severities: [.error, .warning, .note])
        let clamped = HermeticityClamp.apply(to: input, hermeticity: .temporal)

        #expect(clamped.status == .passed)
        #expect(clamped.diagnostics.allSatisfy { $0.severity == .note })
        // The finding itself must survive intact — only its authority is removed.
        #expect(clamped.diagnostics.count == 3)
        #expect(clamped.diagnostics.map(\.ruleId) == input.diagnostics.map(\.ruleId))
        #expect(clamped.diagnostics.map(\.message) == input.diagnostics.map(\.message))
        #expect(clamped.diagnostics.map(\.lineNumber) == input.diagnostics.map(\.lineNumber))
    }

    @Test("External findings clamp the same way as temporal")
    func externalClamped() {
        let input = Self.result(status: .failed, severities: [.error])
        let clamped = HermeticityClamp.apply(to: input, hermeticity: .external)

        #expect(clamped.status == .passed)
        #expect(clamped.diagnostics.map(\.severity) == [.note])
    }

    @Test("Skipped stays skipped — nothing ran, so passing it would be a lie")
    func skippedPreserved() {
        let input = Self.result(status: .skipped, severities: [])
        #expect(HermeticityClamp.apply(to: input, hermeticity: .temporal).status == .skipped)
        #expect(HermeticityClamp.apply(to: input, hermeticity: .external).status == .skipped)
    }

    // MARK: - Runner integration

    @Test("Runner clamps a temporal checker so it cannot fail the gate")
    func runnerClampsTemporal() async {
        let checker = StubChecker(
            id: "temporal",
            hermeticity: .temporal,
            result: Self.result(id: "temporal", status: .failed, severities: [.error]))

        let results = await CheckerRunner().run(
            checkers: [checker],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true)

        #expect(results.count == 1)
        #expect(results[0].status == .passed)
        #expect(results[0].diagnostics.map(\.severity) == [.note])
    }

    @Test("Runner leaves a hermetic checker's failure intact")
    func runnerPreservesHermeticFailure() async {
        let checker = StubChecker(
            id: "hermetic",
            hermeticity: .hermetic,
            result: Self.result(id: "hermetic", status: .failed, severities: [.error]))

        let results = await CheckerRunner().run(
            checkers: [checker],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true)

        #expect(results[0].status == .failed)
        #expect(results[0].diagnostics.map(\.severity) == [.error])
    }

    @Test("--include-nonhermetic restores blocking behavior")
    func includeNonHermeticDisablesClamp() async {
        let checker = StubChecker(
            id: "temporal",
            hermeticity: .temporal,
            result: Self.result(id: "temporal", status: .failed, severities: [.error]))

        let results = await CheckerRunner().run(
            checkers: [checker],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true,
            includeNonHermetic: true)

        #expect(results[0].status == .failed)
        #expect(results[0].diagnostics.map(\.severity) == [.error])
    }

    @Test("An unreachable external checker is skipped with a reason, not failed")
    func externalThrowBecomesSkipped() async {
        let results = await CheckerRunner().run(
            checkers: [ThrowingChecker(hermeticity: .external)],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true)

        #expect(results[0].status == .skipped)
        // The reason must survive so the report can say *why* nothing ran.
        let messages = results[0].diagnostics.map(\.message).joined(separator: " ")
        #expect(messages.contains("network unreachable"))
        #expect(results[0].diagnostics.allSatisfy { $0.severity == .note })
    }

    @Test("A hermetic checker that throws still fails — a broken checker is a real failure")
    func hermeticThrowStillFails() async {
        let results = await CheckerRunner().run(
            checkers: [ThrowingChecker(hermeticity: .hermetic)],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: true)

        #expect(results[0].status == .failed)
    }

    @Test("A temporal checker never triggers early exit under continueOnFailure: false")
    func temporalDoesNotStopTheRun() async {
        let temporal = StubChecker(
            id: "temporal",
            hermeticity: .temporal,
            result: Self.result(id: "temporal", status: .failed, severities: [.error]))
        let downstream = StubChecker(
            id: "downstream",
            hermeticity: .hermetic,
            result: Self.result(id: "downstream", status: .passed, severities: []))

        let results = await CheckerRunner().run(
            checkers: [temporal, downstream],
            configuration: Configuration(),
            strict: false,
            continueOnFailure: false)

        // Both ran: the clamped temporal result must not look like a failure to
        // the early-exit check, or a stale document could suppress real checks.
        #expect(results.count == 2)
        #expect(results.map(\.checkerId) == ["temporal", "downstream"])
    }
}
