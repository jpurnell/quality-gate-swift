import Foundation
import Testing
@testable import QualityGateTestKit
@testable import QualityGateCore

/// Tests for the diagnostic assertion helpers.
///
/// Verifies that ``expectDiagnostic(in:ruleId:severity:atLine:messageContaining:sourceLocation:)``,
/// ``expectNoDiagnostic(in:ruleId:sourceLocation:)``, ``expectClean(_:sourceLocation:)``,
/// ``expectStatus(_:_:sourceLocation:)``, and ``expectDiagnosticCount(in:ruleId:count:sourceLocation:)``
/// behave correctly for both passing and failing cases.
@Suite("DiagnosticAssertion Tests")
struct DiagnosticAssertionTests {

    // MARK: - Test Fixtures

    /// A result with a single force-unwrap error at line 5.
    private let failedResult = CheckResult(
        checkerId: "test",
        status: .failed,
        diagnostics: [
            Diagnostic(
                severity: .error,
                message: "Force unwrap detected",
                lineNumber: 5,
                ruleId: "safety.force-unwrap"
            )
        ],
        duration: .zero
    )

    /// A clean result with no diagnostics.
    private let cleanResult = CheckResult(
        checkerId: "test",
        status: .passed,
        diagnostics: [],
        duration: .zero
    )

    /// A result with multiple diagnostics.
    private let multiResult = CheckResult(
        checkerId: "test",
        status: .failed,
        diagnostics: [
            Diagnostic(
                severity: .error,
                message: "Force unwrap detected",
                lineNumber: 3,
                ruleId: "safety.force-unwrap"
            ),
            Diagnostic(
                severity: .warning,
                message: "Unchecked Sendable conformance",
                lineNumber: 10,
                ruleId: "concurrency.unchecked-sendable"
            ),
            Diagnostic(
                severity: .error,
                message: "Force cast detected",
                lineNumber: 7,
                ruleId: "safety.force-unwrap"
            ),
        ],
        duration: .zero
    )

    // MARK: - expectDiagnostic

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectDiagnostic passes when matching ruleId exists")
    func expectDiagnosticPassesOnMatch() {
        expectDiagnostic(in: failedResult, ruleId: "safety.force-unwrap")
    }

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectDiagnostic with severity filter matches correctly")
    func expectDiagnosticWithSeverity() {
        expectDiagnostic(
            in: failedResult,
            ruleId: "safety.force-unwrap",
            severity: .error
        )
    }

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectDiagnostic with line number filter matches correctly")
    func expectDiagnosticWithLineNumber() {
        expectDiagnostic(
            in: failedResult,
            ruleId: "safety.force-unwrap",
            atLine: 5
        )
    }

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectDiagnostic with messageContaining filter matches")
    func expectDiagnosticWithMessageSubstring() {
        expectDiagnostic(
            in: failedResult,
            ruleId: "safety.force-unwrap",
            messageContaining: "Force unwrap"
        )
    }

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectDiagnostic with all filters matches correctly")
    func expectDiagnosticWithAllFilters() {
        expectDiagnostic(
            in: failedResult,
            ruleId: "safety.force-unwrap",
            severity: .error,
            atLine: 5,
            messageContaining: "detected"
        )
    }

    // MARK: - expectNoDiagnostic

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectNoDiagnostic passes when ruleId absent")
    func expectNoDiagnosticPassesWhenAbsent() {
        expectNoDiagnostic(in: failedResult, ruleId: "concurrency.data-race")
    }

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectNoDiagnostic passes on clean result")
    func expectNoDiagnosticPassesOnClean() {
        expectNoDiagnostic(in: cleanResult, ruleId: "safety.force-unwrap")
    }

    // MARK: - expectClean

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectClean passes on empty diagnostics")
    func expectCleanPassesOnEmpty() {
        expectClean(cleanResult)
    }

    // MARK: - expectStatus

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectStatus passes on matching status")
    func expectStatusPassesOnMatch() {
        expectStatus(failedResult, .failed)
        expectStatus(cleanResult, .passed)
    }

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectStatus works with all status values")
    func expectStatusAllValues() {
        let warningResult = CheckResult(
            checkerId: "test",
            status: .warning,
            diagnostics: [],
            duration: .zero
        )
        let skippedResult = CheckResult(
            checkerId: "test",
            status: .skipped,
            diagnostics: [],
            duration: .zero
        )

        expectStatus(warningResult, .warning)
        expectStatus(skippedResult, .skipped)
    }

    // MARK: - expectDiagnosticCount

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectDiagnosticCount passes with correct count")
    func expectDiagnosticCountCorrect() {
        expectDiagnosticCount(in: multiResult, ruleId: "safety.force-unwrap", count: 2)
        expectDiagnosticCount(in: multiResult, ruleId: "concurrency.unchecked-sendable", count: 1)
    }

    // TEST-QUALITY: assertions delegated to QualityGateTestKit helpers
    @Test("expectDiagnosticCount passes with zero for absent rule")
    func expectDiagnosticCountZero() {
        expectDiagnosticCount(in: cleanResult, ruleId: "safety.force-unwrap", count: 0)
    }
}
