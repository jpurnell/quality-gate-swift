import Foundation
import Testing
@testable import QualityGateCore
@testable import TemporalDeterminismAuditor

/// The markers `VigilKit`'s wall-clock scan honours are named in the record.
@Suite("temporal-determinism: markers are recorded")
struct TemporalSuppressionRecordingTests {

    @Test("`// TIMING:` on a wall-clock assertion is recorded under that form, not as unclassified")
    func timingMarker() async throws {
        let code = """
        import Testing
        @Test func fast() {
            let start = ContinuousClock.now
            work()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(2)) // TIMING: generous ceiling
        }
        """
        let result = try await TemporalDeterminismAuditor().auditSource(
            code, fileName: "/repo/Tests/AppTests/FastTests.swift", configuration: Configuration())
        let records = result.overrides.map(SuppressionRecord.init)

        #expect(records.count == 1)
        #expect(records.first?.form == "// TIMING:")
        #expect(records.first?.source == .marker)
        #expect(records.first?.kind == .suppressed)
        #expect(records.first?.reason == "generous ceiling")
        #expect(records.first?.rejection == "2 words, 8 required")
        #expect(records.first?.lineNumber == 6)
    }

    @Test("Without the marker the assertion is reported and nothing is recorded")
    func noMarker() async throws {
        let code = """
        import Testing
        @Test func fast() {
            let start = ContinuousClock.now
            work()
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(2))
        }
        """
        let result = try await TemporalDeterminismAuditor().auditSource(
            code, fileName: "/repo/Tests/AppTests/FastTests.swift", configuration: Configuration())
        #expect(result.diagnostics.filter { $0.ruleId == "temporal-wall-clock-assertion" }.count == 1)
        #expect(result.overrides.isEmpty)
    }
}
