import Testing
import Foundation
@testable import IJSRefiner
import IJSSensor

@Suite("StatisticalAnomaly")
struct StatisticalAnomalyTests {

    /// 2026-04-25T00:00:00Z, as an instant rather than as text to be parsed.
    ///
    /// A `DateFormatter` round-trip here bought nothing and cost two failure modes: the parse
    /// returns an optional, so the value needed either a trap or a fallback, and a fallback puts
    /// `??` on the same line as a `yyyy-MM-dd` literal — which is exactly the shape
    /// `test-quality`'s `hardcoded-date` rule reads as "a stand-in for now that will drift past
    /// its time window". This is a fixed reference instant, and saying so in seconds makes it
    /// unambiguous and total. The spelling matches `OrientationCardsTests` and
    /// `StoreLocatorFreshnessTests`.
    private let testDate = Date(timeIntervalSince1970: 1_777_075_200)

    private func makeAnomaly(
        direction: AnomalyDirection = .negative,
        severity: AnomalySeverity = .extreme,
        baselineValidity: StatisticalValidity = .valid
    ) -> StatisticalAnomaly {
        StatisticalAnomaly(
            metric: "overrideRate",
            observedValue: 0.33,
            expectedValue: 0.06,
            zScore: 3.37,
            severity: severity,
            date: testDate,
            scope: "quality-gate-swift",
            direction: direction,
            baselineValidity: baselineValidity
        )
    }

    @Test("Golden path: all fields populated")
    func goldenPath() {
        let anomaly = makeAnomaly()
        #expect(anomaly.metric == "overrideRate")
        #expect(abs(anomaly.observedValue - 0.33) < 1e-6)
        #expect(abs(anomaly.expectedValue - 0.06) < 1e-6)
        #expect(abs(anomaly.zScore - 3.37) < 1e-6)
        #expect(anomaly.severity == .extreme)
        #expect(anomaly.scope == "quality-gate-swift")
        #expect(anomaly.direction == .negative)
        #expect(anomaly.baselineValidity == .valid)
    }

    @Test("Direction positive: higher-than-expected pass rate")
    func directionPositive() {
        let anomaly = StatisticalAnomaly(
            metric: "passRate",
            observedValue: 1.0,
            expectedValue: 0.87,
            zScore: 1.82,
            severity: .notable,
            date: testDate,
            scope: "quality-gate-swift",
            direction: .positive,
            baselineValidity: .valid
        )
        #expect(anomaly.direction == .positive)
    }

    @Test("Severity ordering: notable < significant < extreme")
    func severityOrdering() {
        #expect(AnomalySeverity.notable < .significant)
        #expect(AnomalySeverity.significant < .extreme)
        #expect(AnomalySeverity.notable < .extreme)
        #expect(!(AnomalySeverity.extreme < .notable))
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let anomaly = makeAnomaly()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(anomaly)
        let decoded = try decoder.decode(StatisticalAnomaly.self, from: data)
        #expect(decoded == anomaly)
    }

    @Test("Preliminary baseline anomaly carries validity")
    func preliminaryBaseline() {
        let anomaly = makeAnomaly(baselineValidity: .preliminary)
        #expect(anomaly.baselineValidity == .preliminary)
    }

    @Test("Z-score sign: positive z-score with negative direction")
    func zScoreSign() {
        let anomaly = makeAnomaly(direction: .negative)
        #expect(anomaly.zScore > 0)
        #expect(anomaly.direction == .negative)
    }

    @Test("Equatable: matching anomalies are equal")
    func equatable() {
        let a = makeAnomaly()
        let b = makeAnomaly()
        #expect(a == b)
    }
}
