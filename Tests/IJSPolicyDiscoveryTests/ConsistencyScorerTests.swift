import Testing
import Foundation
@testable import IJSPolicyDiscovery
import IJSSensor

@Suite("ScorerWeights")
struct ScorerWeightsTests {

    @Test("Default weights have expected values")
    func defaultWeights() {
        let weights = ScorerWeights.defaults
        #expect(abs(weights.clusterMatch - 0.15) < 1e-6)
        #expect(abs(weights.anomalyPattern - 0.10) < 1e-6)
        #expect(abs(weights.unaddressedPolicy - 0.05) < 1e-6)
        #expect(abs(weights.recurrenceBonus - 0.10) < 1e-6)
        #expect(abs(weights.suppressionPattern - 0.20) < 1e-6)
    }

    @Test("Custom weights are stored")
    func customWeights() {
        let weights = ScorerWeights(
            clusterMatch: 0.20,
            anomalyPattern: 0.15,
            unaddressedPolicy: 0.10,
            recurrenceBonus: 0.05
        )
        #expect(abs(weights.clusterMatch - 0.20) < 1e-6)
        #expect(abs(weights.anomalyPattern - 0.15) < 1e-6)
        #expect(abs(weights.unaddressedPolicy - 0.10) < 1e-6)
        #expect(abs(weights.recurrenceBonus - 0.05) < 1e-6)
    }

    @Test("Codable round-trip preserves values")
    func codableRoundTrip() throws {
        let weights = ScorerWeights.defaults
        let data = try JSONEncoder().encode(weights)
        let decoded = try JSONDecoder().decode(ScorerWeights.self, from: data)
        #expect(decoded == weights)
    }

    @Test("Equatable conformance")
    func equatable() {
        let a = ScorerWeights.defaults
        let b = ScorerWeights.defaults
        let c = ScorerWeights(clusterMatch: 0.20, anomalyPattern: 0.10, unaddressedPolicy: 0.05, recurrenceBonus: 0.10)
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("ConsistencyScorer")
struct ConsistencyScorerTests {

    private func makeFinding(
        matchType: ConsistencyMatchType = .clusterMatch,
        isRecurring: Bool = false
    ) -> ConsistencyFinding {
        ConsistencyFinding(
            ruleId: "test.rule",
            checkerId: "TestAuditor",
            matchType: matchType,
            clusterRiskWeight: 0.3,
            historicalOccurrences: isRecurring ? 5 : 1,
            isRecurringInPulse: isRecurring,
            explanation: "Test"
        )
    }

    @Test("Default init uses default weights")
    func defaultInit() {
        let scorer = ConsistencyScorer()
        #expect(scorer.weights == ScorerWeights.defaults)
    }

    @Test("Custom weights init")
    func customWeightsInit() {
        let weights = ScorerWeights(clusterMatch: 0.20, anomalyPattern: 0.15, unaddressedPolicy: 0.10, recurrenceBonus: 0.05)
        let scorer = ConsistencyScorer(weights: weights)
        #expect(scorer.weights == weights)
    }

    @Test("Empty findings produce score 1.0")
    func emptyFindings() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [])
        #expect(abs(score - 1.0) < 1e-6)
    }

    @Test("Single non-recurring cluster match deducts 0.15")
    func singleClusterMatch() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [makeFinding(matchType: .clusterMatch)])
        #expect(abs(score - 0.85) < 1e-6)
    }

    @Test("Single non-recurring anomaly pattern deducts 0.10")
    func singleAnomalyPattern() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [makeFinding(matchType: .anomalyPattern)])
        #expect(abs(score - 0.90) < 1e-6)
    }

    @Test("Single non-recurring unaddressed policy deducts 0.05")
    func singleUnaddressedPolicy() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [makeFinding(matchType: .unaddressedPolicy)])
        #expect(abs(score - 0.95) < 1e-6)
    }

    @Test("Recurring cluster match deducts 0.25 (0.15 + 0.10 bonus)")
    func recurringClusterMatch() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [makeFinding(matchType: .clusterMatch, isRecurring: true)])
        #expect(abs(score - 0.75) < 1e-6)
    }

    @Test("Recurring anomaly pattern deducts 0.20 (0.10 + 0.10 bonus)")
    func recurringAnomalyPattern() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [makeFinding(matchType: .anomalyPattern, isRecurring: true)])
        #expect(abs(score - 0.80) < 1e-6)
    }

    @Test("Recurring unaddressed policy deducts 0.15 (0.05 + 0.10 bonus)")
    func recurringUnaddressedPolicy() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [makeFinding(matchType: .unaddressedPolicy, isRecurring: true)])
        #expect(abs(score - 0.85) < 1e-6)
    }

    @Test("Multiple findings deduct additively")
    func multipleFindings() {
        let scorer = ConsistencyScorer()
        let findings = [
            makeFinding(matchType: .clusterMatch),
            makeFinding(matchType: .anomalyPattern),
            makeFinding(matchType: .unaddressedPolicy),
        ]
        let score = scorer.score(findings: findings)
        #expect(abs(score - 0.70) < 1e-6)
    }

    @Test("Score clamps to 0.0 floor")
    func clampsToZero() {
        let scorer = ConsistencyScorer()
        let findings = (0..<20).map { _ in makeFinding(matchType: .clusterMatch, isRecurring: true) }
        let score = scorer.score(findings: findings)
        #expect(abs(score - 0.0) < 1e-6)
    }

    @Test("Score never exceeds 1.0")
    func neverExceedsOne() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [])
        #expect(score <= 1.0)
    }

    @Test("Validity discount: valid baseline applies full weight")
    func validBaselineFull() {
        let scorer = ConsistencyScorer()
        let finding = makeFinding(matchType: .clusterMatch)
        let score = scorer.score(findings: [finding], baselineValidity: .valid)
        #expect(abs(score - 0.85) < 1e-6)
    }

    @Test("Validity discount: preliminary baseline applies 50% weight")
    func preliminaryBaselineHalf() {
        let scorer = ConsistencyScorer()
        let finding = makeFinding(matchType: .clusterMatch)
        let score = scorer.score(findings: [finding], baselineValidity: .preliminary)
        #expect(abs(score - 0.925) < 1e-6)
    }

    @Test("Validity discount: insufficient baseline applies 25% weight")
    func insufficientBaselineQuarter() {
        let scorer = ConsistencyScorer()
        let finding = makeFinding(matchType: .clusterMatch)
        let score = scorer.score(findings: [finding], baselineValidity: .insufficient)
        #expect(abs(score - 0.9625) < 1e-6)
    }

    @Test("Mixed recurring and non-recurring with validity discount")
    func mixedWithValidity() {
        let scorer = ConsistencyScorer()
        let findings = [
            makeFinding(matchType: .clusterMatch, isRecurring: true),
            makeFinding(matchType: .anomalyPattern, isRecurring: false),
        ]
        let score = scorer.score(findings: findings, baselineValidity: .preliminary)
        // Full deduction: 0.25 + 0.10 = 0.35, discounted by 0.5 → 0.175
        #expect(abs(score - 0.825) < 1e-6)
    }

    @Test("Custom weights change deduction amounts")
    func customWeightsScoring() {
        let weights = ScorerWeights(
            clusterMatch: 0.30,
            anomalyPattern: 0.20,
            unaddressedPolicy: 0.10,
            recurrenceBonus: 0.05
        )
        let scorer = ConsistencyScorer(weights: weights)
        let score = scorer.score(findings: [makeFinding(matchType: .clusterMatch)])
        #expect(abs(score - 0.70) < 1e-6)
    }

    @Test("Single non-recurring suppression pattern deducts 0.20")
    func singleSuppressionPattern() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [makeFinding(matchType: .suppressionPattern)])
        #expect(abs(score - 0.80) < 1e-6)
    }

    @Test("Recurring suppression pattern deducts 0.30 (0.20 + 0.10 bonus)")
    func recurringSuppressionPattern() {
        let scorer = ConsistencyScorer()
        let score = scorer.score(findings: [makeFinding(matchType: .suppressionPattern, isRecurring: true)])
        #expect(abs(score - 0.70) < 1e-6)
    }

    @Test("Suppression finding deducts from consistency score alongside other findings")
    func suppressionFindingDeductsAlongsideOthers() {
        let scorer = ConsistencyScorer()
        let findings = [
            makeFinding(matchType: .clusterMatch),
            makeFinding(matchType: .suppressionPattern),
        ]
        // cluster: 0.15 + suppression: 0.20 = 0.35 deduction → 0.65
        let score = scorer.score(findings: findings)
        #expect(abs(score - 0.65) < 1e-6)
    }
}
