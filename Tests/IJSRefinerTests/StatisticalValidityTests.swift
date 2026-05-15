import Testing
import Foundation
@testable import IJSRefiner
import IJSSensor

@Suite("StatisticalValidity")
struct StatisticalValidityTests {

    @Test("from(sampleSize: 0) returns insufficient")
    func zeroSamples() {
        #expect(StatisticalValidity.from(sampleSize: 0) == .insufficient)
    }

    @Test("from(sampleSize: 2) returns insufficient")
    func twoSamples() {
        #expect(StatisticalValidity.from(sampleSize: 2) == .insufficient)
    }

    @Test("from(sampleSize: 3) returns preliminary")
    func threeSamples() {
        #expect(StatisticalValidity.from(sampleSize: 3) == .preliminary)
    }

    @Test("from(sampleSize: 29) returns preliminary")
    func twentyNineSamples() {
        #expect(StatisticalValidity.from(sampleSize: 29) == .preliminary)
    }

    @Test("from(sampleSize: 30) returns valid")
    func thirtySamples() {
        #expect(StatisticalValidity.from(sampleSize: 30) == .valid)
    }

    @Test("from(sampleSize: 100) returns valid")
    func hundredSamples() {
        #expect(StatisticalValidity.from(sampleSize: 100) == .valid)
    }

    @Test("Comparable: insufficient < preliminary < valid")
    func comparable() {
        #expect(StatisticalValidity.insufficient < .preliminary)
        #expect(StatisticalValidity.preliminary < .valid)
        #expect(StatisticalValidity.insufficient < .valid)
        #expect(!(StatisticalValidity.valid < .preliminary))
    }

    @Test("Codable round-trip for all cases")
    func codableRoundTrip() throws {
        let cases: [StatisticalValidity] = [.insufficient, .preliminary, .valid]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for validity in cases {
            let data = try encoder.encode(validity)
            let decoded = try decoder.decode(StatisticalValidity.self, from: data)
            #expect(decoded == validity)
        }
    }
}
