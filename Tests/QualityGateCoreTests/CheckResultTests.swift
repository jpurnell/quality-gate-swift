import Foundation
import Testing
@testable import QualityGateCore

/// Tests for the CheckResult model.
///
/// CheckResult represents the outcome of a single quality checker's execution.
@Suite("CheckResult Model Tests")
struct CheckResultTests {

    // MARK: - Initialization Tests

    @Test("CheckResult initializes with passed status and no diagnostics")
    func initializesWithPassedStatus() {
        let result = CheckResult(
            checkerId: "build",
            status: .passed,
            diagnostics: [],
            duration: .seconds(1.5)
        )

        #expect(result.checkerId == "build")
        #expect(result.status == .passed)
        #expect(result.diagnostics.isEmpty)
        #expect(result.duration == .seconds(1.5))
    }

    @Test("CheckResult initializes with failed status and diagnostics")
    func initializesWithFailedStatusAndDiagnostics() {
        let diagnostics = [
            Diagnostic(severity: .error, message: "Build failed"),
            Diagnostic(severity: .error, message: "Undefined symbol")
        ]

        let result = CheckResult(
            checkerId: "build",
            status: .failed,
            diagnostics: diagnostics,
            duration: .seconds(0.5)
        )

        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 2)
    }

    // MARK: - Status Tests

    @Test("Status has correct raw values")
    func statusRawValues() {
        #expect(CheckResult.Status.passed.rawValue == "passed")
        #expect(CheckResult.Status.failed.rawValue == "failed")
        #expect(CheckResult.Status.warning.rawValue == "warning")
        #expect(CheckResult.Status.skipped.rawValue == "skipped")
    }

    @Test("Status isPassing computed property")
    func statusIsPassing() {
        #expect(CheckResult.Status.passed.isPassing == true)
        #expect(CheckResult.Status.warning.isPassing == true)
        #expect(CheckResult.Status.skipped.isPassing == true)
        #expect(CheckResult.Status.failed.isPassing == false)
    }

    // MARK: - Computed Properties

    @Test("errorCount returns count of error-severity diagnostics")
    func errorCountProperty() {
        let diagnostics = [
            Diagnostic(severity: .error, message: "Error 1"),
            Diagnostic(severity: .warning, message: "Warning 1"),
            Diagnostic(severity: .error, message: "Error 2"),
            Diagnostic(severity: .note, message: "Note 1")
        ]

        let result = CheckResult(
            checkerId: "test",
            status: .failed,
            diagnostics: diagnostics,
            duration: .seconds(1)
        )

        #expect(result.errorCount == 2)
    }

    @Test("warningCount returns count of warning-severity diagnostics")
    func warningCountProperty() {
        let diagnostics = [
            Diagnostic(severity: .error, message: "Error 1"),
            Diagnostic(severity: .warning, message: "Warning 1"),
            Diagnostic(severity: .warning, message: "Warning 2"),
            Diagnostic(severity: .note, message: "Note 1")
        ]

        let result = CheckResult(
            checkerId: "test",
            status: .warning,
            diagnostics: diagnostics,
            duration: .seconds(1)
        )

        #expect(result.warningCount == 2)
    }

    // MARK: - Codable Tests

    @Test("CheckResult encodes to JSON correctly")
    func encodesToJSON() throws {
        let result = CheckResult(
            checkerId: "safety",
            status: .passed,
            diagnostics: [],
            duration: .seconds(0.25)
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let json = String(data: data, encoding: .utf8)

        #expect(json != nil)
        #expect(json?.contains("\"checkerId\":\"safety\"") == true)
        #expect(json?.contains("\"status\":\"passed\"") == true)
    }

    @Test("CheckResult round-trips through JSON correctly")
    func roundTripsJSON() throws {
        let original = CheckResult(
            checkerId: "test",
            status: .failed,
            diagnostics: [
                Diagnostic(severity: .error, message: "Test failed")
            ],
            duration: .seconds(2) + .milliseconds(500)
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CheckResult.self, from: data)

        #expect(decoded.checkerId == original.checkerId)
        #expect(decoded.status == original.status)
        #expect(decoded.diagnostics.count == original.diagnostics.count)
        #expect(decoded.duration == original.duration)
    }

    // MARK: - Sendable Compliance

    @Test("CheckResult is Sendable")
    func isSendable() async {
        let result = CheckResult(
            checkerId: "build",
            status: .passed,
            diagnostics: [],
            duration: .seconds(1)
        )

        let checkerId = await Task {
            result.checkerId
        }.value

        #expect(checkerId == "build")
    }
}
