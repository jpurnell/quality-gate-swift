import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

@Suite("ConcurrencyAuditor: cancellation-checkpoint-after-loop")
struct CancellationCheckpointAfterLoopTests {
    private let ruleId = "concurrency.cancellation-checkpoint-after-loop"

    // MARK: - Must flag

    @Test("Flags the harbor shape: checkpoint in loop, dependent code after, no post-loop check")
    func flagsHarborShape() async throws {
        let code = """
        func run(_ stream: AsyncThrowingStream<Int, Error>) async throws {
            for try await sample in stream {
                try Task.checkCancellation()
                process(sample)
            }
            session.markCompleted()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags for-await loop when function uses Task.isCancelled")
    func flagsWithIsCancelledCheckpoint() async throws {
        let code = """
        func run(_ stream: AsyncStream<Int>) async {
            for await sample in stream {
                if Task.isCancelled { break }
                process(sample)
            }
            finish()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Flags even when a defer precedes the dependent statement")
    func flagsWithDeferBeforeDependentCode() async throws {
        let code = """
        func run(_ stream: AsyncStream<Int>) async {
            for await sample in stream {
                try? Task.checkCancellation()
                process(sample)
            }
            defer { cleanup() }
            markCompleted()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Must not flag

    @Test("Does not flag when a cancellation check immediately follows the loop")
    func ignoresCheckedTail() async throws {
        let code = """
        func run(_ stream: AsyncStream<Int>) async throws {
            for await sample in stream {
                try Task.checkCancellation()
                process(sample)
            }
            try Task.checkCancellation()
            session.markCompleted()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag when the guard-on-isCancelled follows the loop")
    func ignoresGuardCheckedTail() async throws {
        let code = """
        func run(_ stream: AsyncStream<Int>) async {
            for await sample in stream {
                if Task.isCancelled { break }
                process(sample)
            }
            guard !Task.isCancelled else { return }
            finish()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag when the enclosing function never uses cancellation")
    func ignoresFunctionWithoutCheckpoint() async throws {
        let code = """
        func run(_ stream: AsyncStream<Int>) async {
            for await sample in stream {
                process(sample)
            }
            finish()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag a plain (non-await) for loop")
    func ignoresPlainForLoop() async throws {
        let code = """
        func run(_ items: [Int]) async {
            try? Task.checkCancellation()
            for item in items {
                process(item)
            }
            finish()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Does not flag when only defer/cleanup follows the loop")
    func ignoresDeferOnlyTail() async throws {
        let code = """
        func run(_ stream: AsyncStream<Int>) async {
            for await sample in stream {
                if Task.isCancelled { break }
                process(sample)
            }
            defer { cleanup() }
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    @Test("Respects // concurrency:exempt on the loop line")
    func respectsExemptMarker() async throws {
        let code = """
        func run(_ stream: AsyncStream<Int>) async {
            for await sample in stream { // concurrency:exempt
                if Task.isCancelled { break }
                process(sample)
            }
            finish()
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(!result.diagnostics.contains { $0.ruleId == ruleId })
    }

    // MARK: - Severity

    @Test("Emits a warning by default")
    func emitsWarningByDefault() async throws {
        let code = """
        func run(_ stream: AsyncStream<Int>) async {
            for await sample in stream {
                if Task.isCancelled { break }
                process(sample)
            }
            finish()
        }
        """
        let result = try await TestHelpers.audit(code)
        let diag = result.diagnostics.first { $0.ruleId == ruleId }
        #expect(diag?.severity == .warning)
    }
}
