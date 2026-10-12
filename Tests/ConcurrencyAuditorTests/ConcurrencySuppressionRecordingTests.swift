import Foundation
import Testing
@testable import ConcurrencyAuditor
@testable import QualityGateCore

/// A `// Justification:` the concurrency rules accept is recorded as an acknowledgement.
///
/// It is the designed, validated form — and it was recorded nowhere. Both call sites read
/// "Justification present — suppress without override record".
@Suite("concurrency: justifications are recorded")
struct ConcurrencySuppressionRecordingTests {

    @Test("An accepted justification on @unchecked Sendable is an acknowledgement")
    func uncheckedSendable() async throws {
        // ApplesoftBASICApp, BlockingInputChannel.swift:27
        let code = """
        // Justification: mutable state is guarded by `stateLock`; the semaphore is only a wake-up hint.
        public final class BlockingInputChannel: @unchecked Sendable {
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "concurrency.unchecked-sendable-no-justification" }.isEmpty)

        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].kind == .acknowledged)
        #expect(records[0].validator == "justification-validator")
        #expect(records[0].form == "// Justification:")
        #expect(records[0].ruleId == "concurrency.unchecked-sendable-no-justification")
        #expect(records[0].lineNumber == 2)
        #expect(records[0].markerLine == 1)
        #expect(records[0].reason == "mutable state is guarded by `stateLock`; the semaphore is only a wake-up hint.")
    }

    @Test("An accepted justification on nonisolated(unsafe) is an acknowledgement")
    func nonisolatedUnsafe() async throws {
        // endoscope, ViewerModel.swift:62
        let code = """
        final class ViewerModel {
            // Justification: read and cancelled only in deinit, where MainActor isolation does not apply.
            nonisolated(unsafe) private var task: Task<Void, Never>?
        }
        """
        let records = try await TestHelpers.audit(code).overrides.map(SuppressionRecord.init)
        #expect(records.map(\.ruleId) == ["concurrency.nonisolated-unsafe-no-justification"])
        #expect(records.map(\.kind) == [.acknowledged])
        #expect(records.map(\.lineNumber) == [3])
    }

    @Test("A justification that fails validation raises its own finding and records nothing")
    func rejectedJustificationIsNotRecorded() async throws {
        let code = """
        // Justification: safe
        public final class Channel: @unchecked Sendable {
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.map(\.ruleId) == ["justification.generic"])
        #expect(result.overrides.isEmpty)
    }

    @Test("Without a justification the rule fires and nothing is recorded")
    func noJustification() async throws {
        let code = """
        public final class Channel: @unchecked Sendable {
        }
        """
        let result = try await TestHelpers.audit(code)
        #expect(result.diagnostics.map(\.ruleId) == ["concurrency.unchecked-sendable-no-justification"])
        #expect(result.overrides.isEmpty)
    }
}
