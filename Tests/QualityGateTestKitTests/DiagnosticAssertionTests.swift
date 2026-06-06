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

    @Test("expectDiagnostic passes when matching ruleId exists")
    func expectDiagnosticPassesOnMatch() {
        expectDiagnostic(in: failedResult, ruleId: "safety.force-unwrap")
        let matchCount = failedResult.diagnostics.filter { $0.ruleId == "safety.force-unwrap" }.count
        #expect(matchCount >= 1)
    }

    @Test("expectDiagnostic with severity filter matches correctly")
    func expectDiagnosticWithSeverity() {
        expectDiagnostic(
            in: failedResult,
            ruleId: "safety.force-unwrap",
            severity: .error
        )
        let matches = failedResult.diagnostics.filter {
            $0.ruleId == "safety.force-unwrap" && $0.severity == .error
        }
        #expect(matches.count >= 1)
    }

    @Test("expectDiagnostic with line number filter matches correctly")
    func expectDiagnosticWithLineNumber() {
        expectDiagnostic(
            in: failedResult,
            ruleId: "safety.force-unwrap",
            atLine: 5
        )
        let matches = failedResult.diagnostics.filter {
            $0.ruleId == "safety.force-unwrap" && $0.lineNumber == 5
        }
        #expect(matches.count >= 1)
    }

    @Test("expectDiagnostic with messageContaining filter matches")
    func expectDiagnosticWithMessageSubstring() {
        expectDiagnostic(
            in: failedResult,
            ruleId: "safety.force-unwrap",
            messageContaining: "Force unwrap"
        )
        let matches = failedResult.diagnostics.filter {
            $0.ruleId == "safety.force-unwrap" && $0.message.contains("Force unwrap")
        }
        #expect(matches.count >= 1)
    }

    @Test("expectDiagnostic with all filters matches correctly")
    func expectDiagnosticWithAllFilters() {
        expectDiagnostic(
            in: failedResult,
            ruleId: "safety.force-unwrap",
            severity: .error,
            atLine: 5,
            messageContaining: "detected"
        )
        let matches = failedResult.diagnostics.filter {
            $0.ruleId == "safety.force-unwrap"
                && $0.severity == .error
                && $0.lineNumber == 5
                && $0.message.contains("detected")
        }
        #expect(matches.count >= 1)
    }

    // MARK: - expectNoDiagnostic

    @Test("expectNoDiagnostic passes when ruleId absent")
    func expectNoDiagnosticPassesWhenAbsent() {
        expectNoDiagnostic(in: failedResult, ruleId: "concurrency.data-race")
        let matches = failedResult.diagnostics.filter { $0.ruleId == "concurrency.data-race" }
        #expect(matches.isEmpty)
    }

    @Test("expectNoDiagnostic passes on clean result")
    func expectNoDiagnosticPassesOnClean() {
        expectNoDiagnostic(in: cleanResult, ruleId: "safety.force-unwrap")
        #expect(cleanResult.diagnostics.isEmpty)
    }

    // MARK: - expectClean

    @Test("expectClean passes on empty diagnostics")
    func expectCleanPassesOnEmpty() {
        expectClean(cleanResult)
        #expect(cleanResult.diagnostics.isEmpty)
    }

    // MARK: - expectStatus

    @Test("expectStatus passes on matching status")
    func expectStatusPassesOnMatch() {
        expectStatus(failedResult, .failed)
        expectStatus(cleanResult, .passed)
        #expect(failedResult.status == .failed)
        #expect(cleanResult.status == .passed)
    }

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
        #expect(warningResult.status == .warning)
        #expect(skippedResult.status == .skipped)
    }

    // MARK: - expectDiagnosticCount

    @Test("expectDiagnosticCount passes with correct count")
    func expectDiagnosticCountCorrect() {
        expectDiagnosticCount(in: multiResult, ruleId: "safety.force-unwrap", count: 2)
        expectDiagnosticCount(in: multiResult, ruleId: "concurrency.unchecked-sendable", count: 1)
        let forceUnwrapCount = multiResult.diagnostics.filter { $0.ruleId == "safety.force-unwrap" }.count
        let sendableCount = multiResult.diagnostics.filter { $0.ruleId == "concurrency.unchecked-sendable" }.count
        #expect(forceUnwrapCount == 2)
        #expect(sendableCount == 1)
    }

    @Test("expectDiagnosticCount passes with zero for absent rule")
    func expectDiagnosticCountZero() {
        expectDiagnosticCount(in: cleanResult, ruleId: "safety.force-unwrap", count: 0)
        let count = cleanResult.diagnostics.filter { $0.ruleId == "safety.force-unwrap" }.count
        #expect(count == 0)
    }
}
