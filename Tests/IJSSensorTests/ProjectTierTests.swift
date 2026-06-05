import Testing
import Foundation
@testable import IJSSensor

@Suite("ProjectTier")
struct ProjectTierTests {

    // MARK: - Raw Values

    @Test("Raw values are camelCase strings")
    func rawValues() {
        #expect(ProjectTier.dormant.rawValue == "dormant")
        #expect(ProjectTier.atRisk.rawValue == "atRisk")
        #expect(ProjectTier.firstContact.rawValue == "firstContact")
        #expect(ProjectTier.baseline.rawValue == "baseline")
        #expect(ProjectTier.active.rawValue == "active")
    }

    // MARK: - Comparable

    @Test("Tiers are ordered: dormant < atRisk < firstContact < baseline < active")
    func comparable() {
        #expect(ProjectTier.dormant < .atRisk)
        #expect(ProjectTier.atRisk < .firstContact)
        #expect(ProjectTier.firstContact < .baseline)
        #expect(ProjectTier.baseline < .active)
        #expect(ProjectTier.dormant < .active)
    }

    // MARK: - Codable Round-Trip

    @Test("Codable round-trip for all cases")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let allCases: [ProjectTier] = [.dormant, .atRisk, .firstContact, .baseline, .active]
        for tier in allCases {
            let data = try encoder.encode(tier)
            let decoded = try decoder.decode(ProjectTier.self, from: data)
            #expect(decoded == tier)
        }
    }

    // MARK: - classify

    @Test("Recent project with many runs classifies as active")
    func classifyActive() {
        let tier = ProjectTier.classify(runCountInWindow: 10, daysSinceLastRun: 0)
        #expect(tier == .active)
    }

    @Test("25 days since last run classifies as atRisk")
    func classifyAtRisk() {
        let tier = ProjectTier.classify(runCountInWindow: 10, daysSinceLastRun: 25)
        #expect(tier == .atRisk)
    }

    @Test("35 days since last run classifies as dormant")
    func classifyDormant() {
        let tier = ProjectTier.classify(runCountInWindow: 10, daysSinceLastRun: 35)
        #expect(tier == .dormant)
    }

    @Test("Single run classifies as firstContact")
    func classifyFirstContact() {
        let tier = ProjectTier.classify(runCountInWindow: 1, daysSinceLastRun: 0)
        #expect(tier == .firstContact)
    }

    @Test("Zero runs classifies as firstContact")
    func classifyZeroRuns() {
        let tier = ProjectTier.classify(runCountInWindow: 0, daysSinceLastRun: 0)
        #expect(tier == .firstContact)
    }

    @Test("Exactly 21 days since last run is atRisk boundary")
    func classifyAtRiskBoundary() {
        let tier = ProjectTier.classify(runCountInWindow: 5, daysSinceLastRun: 21)
        #expect(tier == .atRisk)
    }

    @Test("20 days since last run is just under atRisk threshold")
    func classifyJustUnderAtRisk() {
        let tier = ProjectTier.classify(runCountInWindow: 5, daysSinceLastRun: 20)
        #expect(tier == .active)
    }

    @Test("Exactly 30 days since last run is dormant boundary")
    func classifyDormantBoundary() {
        let tier = ProjectTier.classify(runCountInWindow: 5, daysSinceLastRun: 30)
        #expect(tier == .dormant)
    }

    @Test("29 days since last run is just under dormant threshold")
    func classifyJustUnderDormant() {
        let tier = ProjectTier.classify(runCountInWindow: 5, daysSinceLastRun: 29)
        #expect(tier == .atRisk)
    }
}
