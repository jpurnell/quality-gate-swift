import Testing
import Foundation
@testable import IJSRefiner
import IJSSensor

@Suite("ViolationCluster")
struct ViolationClusterTests {

    private func makeCluster(
        ruleId: String = "concurrency.unchecked-sendable",
        dominantRootCause: String? = "contextually naive",
        dominantFailedStep: FiveStepStage? = .diagnosis,
        isRecurring: Bool = false
    ) -> ViolationCluster {
        ViolationCluster(
            ruleId: ruleId,
            occurrenceCount: 3,
            affectedProjectCount: 2,
            dominantRootCause: dominantRootCause,
            dominantFailedStep: dominantFailedStep,
            isRecurring: isRecurring
        )
    }

    @Test("Golden path: all fields populated")
    func goldenPath() {
        let cluster = makeCluster()
        #expect(cluster.ruleId == "concurrency.unchecked-sendable")
        #expect(cluster.occurrenceCount == 3)
        #expect(cluster.affectedProjectCount == 2)
        #expect(cluster.dominantRootCause == "contextually naive")
        #expect(cluster.dominantFailedStep == .diagnosis)
        #expect(cluster.isRecurring == false)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let cluster = makeCluster()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(cluster)
        let decoded = try decoder.decode(ViolationCluster.self, from: data)
        #expect(decoded == cluster)
    }

    @Test("Nil optionals: dominantRootCause and dominantFailedStep")
    func nilOptionals() throws {
        let cluster = makeCluster(dominantRootCause: nil, dominantFailedStep: nil)
        #expect(cluster.dominantRootCause == nil)
        #expect(cluster.dominantFailedStep == nil)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(cluster)
        let decoded = try decoder.decode(ViolationCluster.self, from: data)
        #expect(decoded == cluster)
    }

    @Test("Equatable: matching clusters equal, differing not")
    func equatable() {
        let a = makeCluster()
        let b = makeCluster()
        let c = makeCluster(ruleId: "safety.force-unwrap")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Recurring cluster")
    func recurring() {
        let cluster = makeCluster(isRecurring: true)
        #expect(cluster.isRecurring == true)
    }

    @Test("consecutiveAppearances defaults to nil for legacy data")
    func consecutiveAppearancesDefault() {
        let cluster = makeCluster()
        #expect(cluster.consecutiveAppearances == nil)
    }

    @Test("consecutiveAppearances round-trips through Codable")
    func consecutiveAppearancesRoundTrip() throws {
        let cluster = ViolationCluster(
            ruleId: "test.rule",
            occurrenceCount: 5,
            affectedProjectCount: 2,
            dominantRootCause: nil,
            dominantFailedStep: nil,
            isRecurring: true,
            consecutiveAppearances: 4
        )
        let data = try JSONEncoder().encode(cluster)
        let decoded = try JSONDecoder().decode(ViolationCluster.self, from: data)
        #expect(decoded.consecutiveAppearances == 4)
    }

    @Test("Decoding legacy JSON without consecutiveAppearances succeeds")
    func decodeLegacyJSON() throws {
        let json = """
        {
            "ruleId": "test.rule",
            "occurrenceCount": 3,
            "affectedProjectCount": 1,
            "isRecurring": true
        }
        """.data(using: .utf8)!
        let cluster = try JSONDecoder().decode(ViolationCluster.self, from: json)
        #expect(cluster.consecutiveAppearances == nil)
        #expect(cluster.isRecurring == true)
    }
}
