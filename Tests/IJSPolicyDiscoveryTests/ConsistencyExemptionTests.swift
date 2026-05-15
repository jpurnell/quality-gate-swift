import Testing
import Foundation
@testable import IJSPolicyDiscovery
import IJSSensor

@Suite("ConsistencyExemption")
struct ConsistencyExemptionTests {

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeExemption(
        ruleId: String = "concurrency.unchecked-sendable",
        matchType: ConsistencyMatchType? = .clusterMatch,
        justification: String = "Legitimate C-interop usage",
        addedDate: String = "2026-04-28",
        approvedBy: String = "jpurnell"
    ) -> ConsistencyExemption {
        ConsistencyExemption(
            ruleId: ruleId,
            matchType: matchType,
            justification: justification,
            addedDate: makeDate(addedDate),
            approvedBy: approvedBy
        )
    }

    @Test("Init stores all fields")
    func initStoresFields() {
        let exemption = makeExemption()
        #expect(exemption.ruleId == "concurrency.unchecked-sendable")
        #expect(exemption.matchType == .clusterMatch)
        #expect(exemption.justification == "Legitimate C-interop usage")
        #expect(exemption.approvedBy == "jpurnell")
    }

    @Test("Nil matchType exempts all match types")
    func nilMatchTypeExemptsAll() {
        let exemption = makeExemption(matchType: nil)
        #expect(exemption.matchType == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exemption = makeExemption()
        let data = try encoder.encode(exemption)
        let decoded = try decoder.decode(ConsistencyExemption.self, from: data)
        #expect(decoded == exemption)
    }

    @Test("Codable round-trip with nil matchType")
    func codableRoundTripNilMatchType() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let exemption = makeExemption(matchType: nil)
        let data = try encoder.encode(exemption)
        let decoded = try decoder.decode(ConsistencyExemption.self, from: data)
        #expect(decoded == exemption)
        #expect(decoded.matchType == nil)
    }

    @Test("Equatable: same fields are equal")
    func equalitySameFields() {
        let a = makeExemption()
        let b = makeExemption()
        #expect(a == b)
    }

    @Test("Equatable: different ruleId are not equal")
    func equalityDifferentRuleId() {
        let a = makeExemption(ruleId: "rule-a")
        let b = makeExemption(ruleId: "rule-b")
        #expect(a != b)
    }

    @Test("Equatable: different matchType are not equal")
    func equalityDifferentMatchType() {
        let a = makeExemption(matchType: .clusterMatch)
        let b = makeExemption(matchType: .anomalyPattern)
        #expect(a != b)
    }
}
