import Foundation
import Testing
@testable import QualityGateCore

/// Tests for the OverrideProcessor.
///
/// Validates that per-rule severity overrides are correctly applied
/// to check results, including exact matches, wildcard patterns,
/// precedence rules, and status recomputation.
@Suite("OverrideProcessor Tests")
struct OverrideProcessorTests {

    // MARK: - Helpers

    /// Creates a diagnostic with the given severity and rule ID.
    private func makeDiagnostic(
        severity: Diagnostic.Severity = .warning,
        message: String = "test issue",
        ruleId: String? = "test.rule"
    ) -> Diagnostic {
        Diagnostic(
            severity: severity,
            message: message,
            filePath: "/test/file.swift",
            lineNumber: 1,
            ruleId: ruleId
        )
    }

    /// Creates a CheckResult with the given diagnostics.
    private func makeResult(
        checkerId: String = "test-checker",
        status: CheckResult.Status = .failed,
        diagnostics: [Diagnostic] = []
    ) -> CheckResult {
        CheckResult(
            checkerId: checkerId,
            status: status,
            diagnostics: diagnostics,
            duration: .milliseconds(100)
        )
    }

    // MARK: - No Overrides

    @Test("No overrides passes result through unchanged")
    func noOverridesPassthrough() {
        let processor = OverrideProcessor(overrides: [:])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = makeResult(diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.status == .failed)
        #expect(processed.diagnostics.count == 1)
        #expect(processed.diagnostics[0].severity == .error)
        #expect(processed.diagnostics[0].ruleId == "safety.force-unwrap")
    }

    // MARK: - Exact Match Overrides

    @Test("Exact match override: error to warning")
    func exactMatchErrorToWarning() {
        let processor = OverrideProcessor(overrides: [
            "safety.force-unwrap": .warning
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = makeResult(diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.diagnostics.count == 1)
        #expect(processed.diagnostics[0].severity == .warning)
        #expect(processed.diagnostics[0].message == "test issue")
    }

    @Test("Exact match override: warning to error")
    func exactMatchWarningToError() {
        let processor = OverrideProcessor(overrides: [
            "concurrency.missing-sendable": .error
        ])
        let diag = makeDiagnostic(severity: .warning, ruleId: "concurrency.missing-sendable")
        let result = makeResult(status: .warning, diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.diagnostics.count == 1)
        #expect(processed.diagnostics[0].severity == .error)
    }

    // MARK: - Override to Off

    @Test("Override to off removes the diagnostic")
    func overrideToOffRemovesDiagnostic() {
        let processor = OverrideProcessor(overrides: [
            "safety.force-unwrap": .off
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = makeResult(diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.diagnostics.isEmpty)
    }

    // MARK: - Override to Info

    @Test("Override to info maps severity to .note")
    func overrideToInfoMapsToNote() {
        let processor = OverrideProcessor(overrides: [
            "safety.force-unwrap": .info
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = makeResult(diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.diagnostics.count == 1)
        #expect(processed.diagnostics[0].severity == .note)
    }

    // MARK: - Wildcard Overrides

    @Test("Wildcard override matches rule prefix")
    func wildcardOverrideMatchesPrefix() {
        let processor = OverrideProcessor(overrides: [
            "safety.*": .warning
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = makeResult(diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.diagnostics.count == 1)
        #expect(processed.diagnostics[0].severity == .warning)
    }

    // MARK: - Precedence

    @Test("Specific override takes precedence over wildcard")
    func specificOverridesPrecedence() {
        let processor = OverrideProcessor(overrides: [
            "safety.*": .off,
            "safety.force-unwrap": .warning
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = makeResult(diagnostics: [diag])

        let processed = processor.apply(to: result)

        // Specific rule keeps the diagnostic as warning; wildcard would remove it
        #expect(processed.diagnostics.count == 1)
        #expect(processed.diagnostics[0].severity == .warning)
    }

    // MARK: - Status Recomputation

    @Test("Status recomputed: all errors overridden to warning becomes .warning")
    func statusRecomputedToWarning() {
        let processor = OverrideProcessor(overrides: [
            "safety.force-unwrap": .warning
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = makeResult(status: .failed, diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.status == .warning)
    }

    @Test("Status recomputed: all diagnostics removed becomes .passed")
    func statusRecomputedToPassed() {
        let processor = OverrideProcessor(overrides: [
            "safety.force-unwrap": .off
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = makeResult(status: .failed, diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.status == .passed)
    }

    // MARK: - Nil ruleId

    @Test("Diagnostics with nil ruleId are not affected by overrides")
    func nilRuleIdNotAffected() {
        let processor = OverrideProcessor(overrides: [
            "safety.*": .off
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: nil)
        let result = makeResult(diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.diagnostics.count == 1)
        #expect(processed.diagnostics[0].severity == .error)
    }

    // MARK: - No-Match Override

    @Test("Override key that doesn't match any diagnostic has no effect")
    func noMatchOverrideNoEffect() {
        let processor = OverrideProcessor(overrides: [
            "nonexistent.rule": .off
        ])
        let diag = makeDiagnostic(severity: .warning, ruleId: "safety.force-unwrap")
        let result = makeResult(status: .warning, diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.diagnostics.count == 1)
        #expect(processed.diagnostics[0].severity == .warning)
        #expect(processed.status == .warning)
    }

    // MARK: - Multiple Overrides

    @Test("Multiple overrides applied to different diagnostics in same result")
    func multipleOverridesDifferentDiagnostics() {
        let processor = OverrideProcessor(overrides: [
            "safety.force-unwrap": .warning,
            "concurrency.missing-sendable": .off
        ])
        let diag1 = makeDiagnostic(severity: .error, message: "force unwrap", ruleId: "safety.force-unwrap")
        let diag2 = makeDiagnostic(severity: .warning, message: "missing sendable", ruleId: "concurrency.missing-sendable")
        let diag3 = makeDiagnostic(severity: .note, message: "info only", ruleId: "doc.coverage")
        let result = makeResult(status: .failed, diagnostics: [diag1, diag2, diag3])

        let processed = processor.apply(to: result)

        // diag1 downgraded to warning, diag2 removed, diag3 untouched
        #expect(processed.diagnostics.count == 2)
        #expect(processed.diagnostics[0].severity == .warning)
        #expect(processed.diagnostics[0].message == "force unwrap")
        #expect(processed.diagnostics[1].severity == .note)
        #expect(processed.diagnostics[1].message == "info only")
        #expect(processed.status == .warning)
    }

    // MARK: - Preserves Other Fields

    @Test("Override preserves non-severity diagnostic fields")
    func overridePreservesDiagnosticFields() {
        let processor = OverrideProcessor(overrides: [
            "safety.force-unwrap": .warning
        ])
        let diag = Diagnostic(
            severity: .error,
            message: "Force unwrap detected",
            filePath: "/path/to/File.swift",
            lineNumber: 42,
            columnNumber: 10,
            ruleId: "safety.force-unwrap",
            suggestedFix: "Use optional binding"
        )
        let result = makeResult(diagnostics: [diag])

        let processed = processor.apply(to: result)

        let d = processed.diagnostics[0]
        #expect(d.severity == .warning)
        #expect(d.message == "Force unwrap detected")
        #expect(d.filePath == "/path/to/File.swift")
        #expect(d.lineNumber == 42)
        #expect(d.columnNumber == 10)
        #expect(d.ruleId == "safety.force-unwrap")
        #expect(d.suggestedFix == "Use optional binding")
    }

    // MARK: - Skipped Status Preserved

    @Test("Skipped result status is preserved even with overrides")
    func skippedStatusPreserved() {
        let processor = OverrideProcessor(overrides: [
            "safety.*": .off
        ])
        let result = makeResult(checkerId: "test", status: .skipped, diagnostics: [])

        let processed = processor.apply(to: result)

        #expect(processed.status == .skipped)
    }

    // MARK: - CheckResult Fields Preserved

    @Test("Override preserves checkerId and duration")
    func preservesCheckResultFields() {
        let processor = OverrideProcessor(overrides: [
            "safety.force-unwrap": .warning
        ])
        let diag = makeDiagnostic(severity: .error, ruleId: "safety.force-unwrap")
        let result = CheckResult(
            checkerId: "my-checker",
            status: .failed,
            diagnostics: [diag],
            duration: .milliseconds(500)
        )

        let processed = processor.apply(to: result)

        #expect(processed.checkerId == "my-checker")
        #expect(processed.duration == .milliseconds(500))
    }

    // MARK: - Status Recomputation: Warning Upgraded to Error

    @Test("Warning diagnostic upgraded to error makes status .failed")
    func warningUpgradedToErrorMakesStatusFailed() {
        let processor = OverrideProcessor(overrides: [
            "concurrency.missing-sendable": .error
        ])
        let diag = makeDiagnostic(severity: .warning, ruleId: "concurrency.missing-sendable")
        let result = makeResult(status: .warning, diagnostics: [diag])

        let processed = processor.apply(to: result)

        #expect(processed.diagnostics[0].severity == .error)
        #expect(processed.status == .failed)
    }
}
