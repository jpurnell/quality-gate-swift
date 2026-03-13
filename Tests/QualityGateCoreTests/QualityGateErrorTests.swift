import Foundation
import Testing
@testable import QualityGateCore

/// Tests for QualityGateError.
///
/// These tests verify the error types match our Error Registry.
@Suite("QualityGateError Tests")
struct QualityGateErrorTests {

    // MARK: - Error Case Tests

    @Test("buildFailed contains exit code and output")
    func buildFailedError() {
        let error = QualityGateError.buildFailed(exitCode: 1, output: "error: undefined symbol")

        if case .buildFailed(let exitCode, let output) = error {
            #expect(exitCode == 1)
            #expect(output.contains("undefined symbol"))
        } else {
            Issue.record("Expected buildFailed case")
        }
    }

    @Test("testsFailed contains failure count")
    func testsFailedError() {
        let error = QualityGateError.testsFailed(count: 5)

        if case .testsFailed(let count) = error {
            #expect(count == 5)
        } else {
            Issue.record("Expected testsFailed case")
        }
    }

    @Test("safetyViolation contains violation count")
    func safetyViolationError() {
        let error = QualityGateError.safetyViolation(count: 3)

        if case .safetyViolation(let count) = error {
            #expect(count == 3)
        } else {
            Issue.record("Expected safetyViolation case")
        }
    }

    @Test("docLintFailed contains issue count")
    func docLintFailedError() {
        let error = QualityGateError.docLintFailed(issueCount: 10)

        if case .docLintFailed(let count) = error {
            #expect(count == 10)
        } else {
            Issue.record("Expected docLintFailed case")
        }
    }

    @Test("configurationError contains description")
    func configurationErrorCase() {
        let error = QualityGateError.configurationError("Invalid YAML syntax")

        if case .configurationError(let description) = error {
            #expect(description.contains("Invalid YAML"))
        } else {
            Issue.record("Expected configurationError case")
        }
    }

    @Test("processTimeout contains command and timeout duration")
    func processTimeoutError() {
        let error = QualityGateError.processTimeout(command: "swift build", timeout: .seconds(120))

        if case .processTimeout(let command, let timeout) = error {
            #expect(command == "swift build")
            #expect(timeout == .seconds(120))
        } else {
            Issue.record("Expected processTimeout case")
        }
    }

    // MARK: - LocalizedError Conformance

    @Test("Errors provide user-friendly descriptions")
    func errorDescriptions() {
        let errors: [QualityGateError] = [
            .buildFailed(exitCode: 1, output: "error"),
            .testsFailed(count: 2),
            .safetyViolation(count: 1),
            .docLintFailed(issueCount: 3),
            .configurationError("bad config"),
            .processTimeout(command: "cmd", timeout: .seconds(60))
        ]

        for error in errors {
            let description = error.localizedDescription
            #expect(description.isEmpty == false)
        }
    }

    // MARK: - Sendable Compliance

    @Test("QualityGateError is Sendable")
    func isSendable() async {
        let error = QualityGateError.buildFailed(exitCode: 1, output: "test")

        let result = await Task {
            error.localizedDescription
        }.value

        #expect(result.isEmpty == false)
    }
}
