import Foundation
import Testing
@testable import QualityGateCore

/// Tests for the QualityChecker protocol.
///
/// These tests verify the contract that all quality checkers must implement.
@Suite("QualityChecker Protocol Tests")
struct QualityCheckerTests {

    // MARK: - Mock Implementation for Testing

    /// A mock checker for testing protocol requirements.
    struct MockChecker: QualityChecker {
        let id: String
        let name: String
        let shouldPass: Bool
        let mockDiagnostics: [Diagnostic]

        init(
            id: String = "mock",
            name: String = "Mock Checker",
            shouldPass: Bool = true,
            mockDiagnostics: [Diagnostic] = []
        ) {
            self.id = id
            self.name = name
            self.shouldPass = shouldPass
            self.mockDiagnostics = mockDiagnostics
        }

        func check(configuration: Configuration) async throws -> CheckResult {
            CheckResult(
                checkerId: id,
                status: shouldPass ? .passed : .failed,
                diagnostics: mockDiagnostics,
                duration: .seconds(0.1)
            )
        }
    }

    // MARK: - Protocol Conformance Tests

    @Test("Checker returns result with correct checkerId")
    func returnsCorrectCheckerId() async throws {
        let checker = MockChecker(id: "test-checker")
        let config = Configuration()

        let result = try await checker.check(configuration: config)

        #expect(result.checkerId == "test-checker")
    }

    @Test("Checker returns passed status when successful")
    func returnsPassedStatus() async throws {
        let checker = MockChecker(shouldPass: true)
        let config = Configuration()

        let result = try await checker.check(configuration: config)

        #expect(result.status == .passed)
    }

    @Test("Checker returns failed status with diagnostics")
    func returnsFailedStatusWithDiagnostics() async throws {
        let diagnostics = [
            Diagnostic(severity: .error, message: "Something went wrong")
        ]
        let checker = MockChecker(shouldPass: false, mockDiagnostics: diagnostics)
        let config = Configuration()

        let result = try await checker.check(configuration: config)

        #expect(result.status == .failed)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.message == "Something went wrong")
    }

    // MARK: - Sendable Tests

    @Test("QualityChecker implementations are Sendable")
    func checkerIsSendable() async {
        let checker = MockChecker()

        // Pass across concurrency boundary
        let id = await Task {
            checker.id
        }.value

        #expect(id == "mock")
    }

    // MARK: - Concurrent Execution Tests

    @Test("Multiple checkers can run concurrently")
    func multipleConcurrentCheckers() async throws {
        let checkers: [any QualityChecker] = [
            MockChecker(id: "checker-1"),
            MockChecker(id: "checker-2"),
            MockChecker(id: "checker-3")
        ]
        let config = Configuration()

        let results = try await withThrowingTaskGroup(of: CheckResult.self) { group in
            for checker in checkers {
                group.addTask {
                    try await checker.check(configuration: config)
                }
            }

            var collected: [CheckResult] = []
            for try await result in group {
                collected.append(result)
            }
            return collected
        }

        #expect(results.count == 3)
        let ids = Set(results.map(\.checkerId))
        #expect(ids.contains("checker-1"))
        #expect(ids.contains("checker-2"))
        #expect(ids.contains("checker-3"))
    }
}
