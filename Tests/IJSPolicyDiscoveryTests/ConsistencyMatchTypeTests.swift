import Testing
import Foundation
@testable import IJSPolicyDiscovery
import IJSSensor

@Suite("ConsistencyMatchType")
struct ConsistencyMatchTypeTests {

    @Test("All cases have expected raw values")
    func rawValues() {
        #expect(ConsistencyMatchType.clusterMatch.rawValue == "clusterMatch")
        #expect(ConsistencyMatchType.anomalyPattern.rawValue == "anomalyPattern")
        #expect(ConsistencyMatchType.unaddressedPolicy.rawValue == "unaddressedPolicy")
        #expect(ConsistencyMatchType.suppressionPattern.rawValue == "suppressionPattern")
    }

    @Test("Codable round-trip preserves value")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for matchType in [ConsistencyMatchType.clusterMatch, .anomalyPattern, .unaddressedPolicy, .suppressionPattern] {
            let data = try encoder.encode(matchType)
            let decoded = try decoder.decode(ConsistencyMatchType.self, from: data)
            #expect(decoded == matchType)
        }
    }

    @Test("Decodes from JSON string")
    func decodesFromJSON() throws {
        let json = Data(#""clusterMatch""#.utf8)
        let decoded = try JSONDecoder().decode(ConsistencyMatchType.self, from: json)
        #expect(decoded == .clusterMatch)
    }

    @Test("Invalid raw value fails to decode")
    func invalidRawValueFails() {
        let json = Data(#""invalidType""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ConsistencyMatchType.self, from: json)
        }
    }

    @Test("Equatable conformance")
    func equatable() {
        #expect(ConsistencyMatchType.clusterMatch == ConsistencyMatchType.clusterMatch)
        #expect(ConsistencyMatchType.clusterMatch != ConsistencyMatchType.anomalyPattern)
    }
}
