import Foundation
import SwiftParser
import Testing
@testable import MemoryLifecycleGuard
@testable import QualityGateCore

/// `lifecycle:exempt` silences a finding and leaves a record that it did.
@Suite("memory-lifecycle: markers are recorded")
struct LifecycleSuppressionRecordingTests {

    /// What the checker's file loop does for one file: the real walk, then the marker records.
    private func audit(_ code: String) -> (diagnostics: [Diagnostic], overrides: [DiagnosticOverride]) {
        let real = diagnose(code)
        let records = MemoryLifecycleGuard.markerRecords(
            source: code, filePath: "test.swift", real: real, config: .default)
        return (real, records)
    }

    @Test("An exempt Task property with no deinit is recorded against lifecycle-task-no-deinit")
    func exemptTaskProperty() {
        // IconquerApp, MultiplayerViewModel.swift:62
        let code = """
        final class MultiplayerViewModel {
            private var messageTask: Task<Void, Never>? // lifecycle:exempt — captures [weak self], self-terminates on dealloc
        }
        """
        let result = audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "lifecycle-task-no-deinit" }.isEmpty)

        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].form == "lifecycle:exempt")
        #expect(records[0].ruleId == "lifecycle-task-no-deinit")
        #expect(records[0].kind == .suppressed)
        #expect(records[0].reason == "captures [weak self], self-terminates on dealloc")
        #expect(records[0].rejection == "6 words, 8 required")
        #expect(records[0].markerLine == 2)
    }

    @Test("Without the marker the finding is raised and nothing is recorded")
    func noMarker() {
        let code = """
        final class MultiplayerViewModel {
            private var messageTask: Task<Void, Never>?
        }
        """
        let result = audit(code)
        #expect(result.diagnostics.filter { $0.ruleId == "lifecycle-task-no-deinit" }.count == 1)
        #expect(result.overrides.isEmpty)
    }

    @Test("A marker on a property the rules have no quarrel with is not recorded")
    func decorativeMarker() {
        let code = """
        final class Model {
            private var count: Int = 0 // lifecycle:exempt — nothing here needs exempting from anything at all
        }
        """
        #expect(audit(code).overrides.isEmpty)
    }
}
