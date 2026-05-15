import Testing
import Foundation
@testable import IJSPolicyDiscovery
import IJSSensor

@Suite("ConsistencyFinding")
struct ConsistencyFindingTests {

    private func makeFinding(
        ruleId: String = "concurrency.unchecked-sendable",
        checkerId: String = "ConcurrencyAuditor",
        matchType: ConsistencyMatchType = .clusterMatch,
        clusterRiskWeight: Double = 0.3,
        historicalOccurrences: Int = 5,
        isRecurringInPulse: Bool = true,
        explanation: String = "Pattern appeared in 3 consecutive Pulses"
    ) -> ConsistencyFinding {
        ConsistencyFinding(
            ruleId: ruleId,
            checkerId: checkerId,
            matchType: matchType,
            clusterRiskWeight: clusterRiskWeight,
            historicalOccurrences: historicalOccurrences,
            isRecurringInPulse: isRecurringInPulse,
            explanation: explanation
        )
    }

    @Test("Init stores all fields")
    func initStoresFields() {
        let finding = makeFinding()
        #expect(finding.ruleId == "concurrency.unchecked-sendable")
        #expect(finding.checkerId == "ConcurrencyAuditor")
        #expect(finding.matchType == .clusterMatch)
        #expect(abs(finding.clusterRiskWeight - 0.3) < 1e-6)
        #expect(finding.historicalOccurrences == 5)
        #expect(finding.isRecurringInPulse == true)
        #expect(finding.explanation == "Pattern appeared in 3 consecutive Pulses")
    }

    @Test("Non-recurring finding")
    func nonRecurring() {
        let finding = makeFinding(historicalOccurrences: 1, isRecurringInPulse: false)
        #expect(finding.isRecurringInPulse == false)
        #expect(finding.historicalOccurrences == 1)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let finding = makeFinding()
        let data = try encoder.encode(finding)
        let decoded = try decoder.decode(ConsistencyFinding.self, from: data)
        #expect(decoded == finding)
    }

    @Test("Equatable: same fields are equal")
    func equalitySame() {
        #expect(makeFinding() == makeFinding())
    }

    @Test("Equatable: different matchType are not equal")
    func equalityDifferentMatchType() {
        let a = makeFinding(matchType: .clusterMatch)
        let b = makeFinding(matchType: .anomalyPattern)
        #expect(a != b)
    }

    @Test("Different match types produce distinct findings")
    func allMatchTypes() {
        let cluster = makeFinding(matchType: .clusterMatch)
        let anomaly = makeFinding(matchType: .anomalyPattern)
        let policy = makeFinding(matchType: .unaddressedPolicy)
        #expect(cluster != anomaly)
        #expect(anomaly != policy)
        #expect(cluster != policy)
    }
}
