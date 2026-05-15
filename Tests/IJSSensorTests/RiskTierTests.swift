import Testing
import Foundation
@testable import IJSSensor

@Suite("RiskTier")
struct RiskTierTests {

    // MARK: - Raw Values

    @Test("Raw values match tier numbering")
    func rawValues() {
        #expect(RiskTier.informational.rawValue == 1)
        #expect(RiskTier.operational.rawValue == 2)
        #expect(RiskTier.safety.rawValue == 3)
        #expect(RiskTier.critical.rawValue == 4)
    }

    // MARK: - Required Authority Mapping

    @Test("Informational tier requires practitioner authority")
    func informationalAuthority() {
        #expect(RiskTier.informational.requiredAuthority == .practitioner)
    }

    @Test("Operational tier requires peer authority")
    func operationalAuthority() {
        #expect(RiskTier.operational.requiredAuthority == .peer)
    }

    @Test("Safety tier requires decision owner authority")
    func safetyAuthority() {
        #expect(RiskTier.safety.requiredAuthority == .decisionOwner)
    }

    @Test("Critical tier requires executive authority")
    func criticalAuthority() {
        #expect(RiskTier.critical.requiredAuthority == .executive)
    }

    // MARK: - Comparable

    @Test("Risk tiers are ordered by severity")
    func comparable() {
        #expect(RiskTier.informational < .operational)
        #expect(RiskTier.operational < .safety)
        #expect(RiskTier.safety < .critical)
        #expect(RiskTier.informational < .critical)
    }

    // MARK: - Codable Round-Trip

    @Test("RiskTier encodes and decodes correctly")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for tier in [RiskTier.informational, .operational, .safety, .critical] {
            let data = try encoder.encode(tier)
            let decoded = try decoder.decode(RiskTier.self, from: data)
            #expect(decoded == tier)
        }
    }

    @Test("RiskTier encodes as integer")
    func encodesAsInteger() throws {
        let data = try JSONEncoder().encode(RiskTier.safety)
        let jsonString = String(data: data, encoding: .utf8)
        #expect(jsonString == "3")
    }
}

@Suite("AuthorityLevel")
struct AuthorityLevelTests {

    @Test("Raw string values use camelCase")
    func rawValues() {
        #expect(AuthorityLevel.practitioner.rawValue == "practitioner")
        #expect(AuthorityLevel.peer.rawValue == "peer")
        #expect(AuthorityLevel.decisionOwner.rawValue == "decisionOwner")
        #expect(AuthorityLevel.executive.rawValue == "executive")
    }

    @Test("AuthorityLevel encodes and decodes correctly")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for level in [AuthorityLevel.practitioner, .peer, .decisionOwner, .executive] {
            let data = try encoder.encode(level)
            let decoded = try decoder.decode(AuthorityLevel.self, from: data)
            #expect(decoded == level)
        }
    }

    @Test("AuthorityLevel encodes as camelCase string")
    func encodesAsCamelCase() throws {
        let data = try JSONEncoder().encode(AuthorityLevel.decisionOwner)
        let jsonString = String(data: data, encoding: .utf8)
        #expect(jsonString == "\"decisionOwner\"")
    }
}
