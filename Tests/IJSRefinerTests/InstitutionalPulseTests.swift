import Testing
import Foundation
@testable import IJSRefiner
import IJSSensor

@Suite("InstitutionalPulse")
struct InstitutionalPulseTests {

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeStats() -> PulseStatistics {
        PulseStatistics(
            totalGateRuns: 47, passedRuns: 41, failedRuns: 6,
            totalOverrides: 3, totalCalibrations: 3,
            overridesByRiskTier: [.safety: 2], failuresByChecker: ["SafetyAuditor": 2],
            rootCauseDistribution: ["expedient": 1], failedStepDistribution: [.design: 1],
            meanConsistencyScore: 0.82,
            corpusTrends: [], projectTrends: [:], anomalies: [],
            corpusSnapshots: [], projectSnapshots: [:]
        )
    }

    private func makePulse(narrative: String? = nil) -> InstitutionalPulse {
        InstitutionalPulse(
            windowStart: makeDate("2026-04-21"),
            windowEnd: makeDate("2026-04-28"),
            weekLabel: "2026-W18",
            projects: ["quality-gate-swift", "business-math"],
            statistics: makeStats(),
            violationClusters: [],
            proposedPolicyUpdates: ["Add concurrency guidance"],
            calibrationSummaries: ["Override on Worker.swift justified by C interop."],
            narrative: narrative,
            generatedAt: makeDate("2026-04-28")
        )
    }

    @Test("Golden path: full Pulse with all fields")
    func goldenPath() {
        let pulse = makePulse()
        #expect(pulse.weekLabel == "2026-W18")
        #expect(pulse.projects.count == 2)
        #expect(pulse.statistics.totalGateRuns == 47)
        #expect(pulse.proposedPolicyUpdates.count == 1)
        #expect(pulse.calibrationSummaries.count == 1)
        #expect(pulse.narrative == nil)
    }

    @Test("Codable round-trip preserves all nested types")
    func codableRoundTrip() throws {
        let pulse = makePulse(narrative: "This week saw stable pass rates.")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(pulse)
        let decoded = try decoder.decode(InstitutionalPulse.self, from: data)
        #expect(decoded == pulse)
    }

    @Test("Nil narrative")
    func nilNarrative() {
        let pulse = makePulse(narrative: nil)
        #expect(pulse.narrative == nil)
    }

    @Test("Populated narrative")
    func populatedNarrative() {
        let pulse = makePulse(narrative: "Override rate spiked on Friday.")
        #expect(pulse.narrative == "Override rate spiked on Friday.")
    }

    @Test("ISO 8601 dates in JSON output")
    func iso8601Dates() throws {
        let pulse = makePulse()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(pulse)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("2026-04-21"))
        #expect(json.contains("2026-04-28"))
    }

    @Test("Empty arrays handled correctly")
    func emptyArrays() {
        let pulse = InstitutionalPulse(
            windowStart: makeDate("2026-04-21"),
            windowEnd: makeDate("2026-04-28"),
            weekLabel: "2026-W18",
            projects: [],
            statistics: PulseStatistics(
                totalGateRuns: 0, passedRuns: 0, failedRuns: 0,
                totalOverrides: 0, totalCalibrations: 0,
                overridesByRiskTier: [:], failuresByChecker: [:],
                rootCauseDistribution: [:], failedStepDistribution: [:],
                meanConsistencyScore: nil,
                corpusTrends: [], projectTrends: [:], anomalies: [],
                corpusSnapshots: [], projectSnapshots: [:]
            ),
            violationClusters: [],
            proposedPolicyUpdates: [],
            calibrationSummaries: [],
            narrative: nil,
            generatedAt: makeDate("2026-04-28")
        )
        #expect(pulse.projects.isEmpty)
        #expect(pulse.violationClusters.isEmpty)
        #expect(pulse.statistics.totalGateRuns == 0)
    }
}
