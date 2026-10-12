import Foundation
import Testing
@testable import QualityGateCore
@testable import StochasticDeterminismAuditor

/// A reasoned `stochastic:exempt` silences a finding and leaves a record that it did.
@Suite("stochastic-determinism: markers are recorded")
struct StochasticSuppressionRecordingTests {

    private func audit(_ code: String) async throws -> CheckResult {
        try await StochasticDeterminismAuditor().auditSource(
            code, fileName: "Sources/App/Game.swift", configuration: Configuration())
    }

    @Test("A marker with a short reason silences the finding and is recorded as a suppression")
    func shortReason() async throws {
        // IconquerApp, GameViewModel.swift:100
        let code = """
        func start(seed: UInt32?) {
            let gameSeed = seed ?? UInt32.random(in: 0...UInt32.max) // stochastic:exempt — this IS the seed generation
            _ = gameSeed
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.isEmpty)

        let records = result.overrides.map(SuppressionRecord.init)
        #expect(records.count == 1)
        #expect(records[0].form == "stochastic:exempt")
        #expect(records[0].ruleId == "stochastic-no-seed")
        #expect(records[0].kind == .suppressed)
        #expect(records[0].reason == "this IS the seed generation")
        #expect(records[0].rejection == "5 words, 8 required")
        #expect(records[0].lineNumber == 2)
    }

    @Test("A bare marker is reported in its own right, so nothing is silent and nothing is recorded")
    func bareMarker() async throws {
        let code = """
        func start() {
            let gameSeed = UInt32.random(in: 0...UInt32.max) // stochastic:exempt
            _ = gameSeed
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.map(\.ruleId) == ["stochastic.exempt-no-justification"])
        #expect(result.overrides.isEmpty)
    }

    @Test("Without the marker the finding is raised and nothing is recorded")
    func noMarker() async throws {
        let code = """
        func start() {
            let gameSeed = UInt32.random(in: 0...UInt32.max)
            _ = gameSeed
        }
        """
        let result = try await audit(code)
        #expect(result.diagnostics.map(\.ruleId) == ["stochastic-no-seed"])
        #expect(result.overrides.isEmpty)
    }
}
