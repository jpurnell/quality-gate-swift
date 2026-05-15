import Testing
import Foundation
@testable import IJSSensor

@Suite("DailySnapshot")
struct DailySnapshotTests {

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeSnapshot(
        gateRuns: Int = 12,
        passedRuns: Int = 10,
        failedRuns: Int = 2,
        overrides: Int = 1,
        calibrations: Int = 1
    ) -> DailySnapshot {
        DailySnapshot(
            date: makeDate("2026-04-28"),
            scope: "quality-gate-swift",
            gateRuns: gateRuns,
            passedRuns: passedRuns,
            failedRuns: failedRuns,
            overrides: overrides,
            calibrations: calibrations,
            failuresByChecker: ["ConcurrencyAuditor": 1, "SafetyAuditor": 1],
            overridesByRiskTier: [.safety: 1]
        )
    }

    @Test("Golden path: all fields populated and rates correct")
    func goldenPath() {
        let snapshot = makeSnapshot()
        #expect(snapshot.scope == "quality-gate-swift")
        #expect(snapshot.gateRuns == 12)
        #expect(snapshot.passedRuns == 10)
        #expect(snapshot.failedRuns == 2)
        #expect(snapshot.overrides == 1)
        #expect(snapshot.calibrations == 1)
        #expect(snapshot.failuresByChecker["ConcurrencyAuditor"] == 1)
        #expect(snapshot.overridesByRiskTier[.safety] == 1)
    }

    @Test("Pass rate computed correctly")
    func passRate() {
        let snapshot = makeSnapshot(gateRuns: 12, passedRuns: 10)
        #expect(abs(snapshot.passRate - (10.0 / 12.0)) < 0.001)
    }

    @Test("Failure rate computed correctly")
    func failureRate() {
        let snapshot = makeSnapshot(gateRuns: 12, failedRuns: 2)
        #expect(abs(snapshot.failureRate - (2.0 / 12.0)) < 0.001)
    }

    @Test("Override rate computed correctly")
    func overrideRate() {
        let snapshot = makeSnapshot(gateRuns: 12, overrides: 3)
        #expect(abs(snapshot.overrideRate - (3.0 / 12.0)) < 0.001)
    }

    @Test("Calibration rate computed correctly")
    func calibrationRate() {
        let snapshot = makeSnapshot(gateRuns: 12, calibrations: 2)
        #expect(abs(snapshot.calibrationRate - (2.0 / 12.0)) < 0.001)
    }

    @Test("Zero gate runs returns 0 for all rates")
    func zeroGateRuns() {
        let snapshot = makeSnapshot(gateRuns: 0, passedRuns: 0, failedRuns: 0, overrides: 0, calibrations: 0)
        #expect(abs(snapshot.passRate - 0.0) < 1e-6)
        #expect(abs(snapshot.failureRate - 0.0) < 1e-6)
        #expect(abs(snapshot.overrideRate - 0.0) < 1e-6)
        #expect(abs(snapshot.calibrationRate - 0.0) < 1e-6)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let snapshot = makeSnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(DailySnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test("Dictionary fields round-trip through Codable")
    func dictionaryFieldsRoundTrip() throws {
        let snapshot = DailySnapshot(
            date: makeDate("2026-04-28"),
            scope: "test-project",
            gateRuns: 5,
            passedRuns: 3,
            failedRuns: 2,
            overrides: 2,
            calibrations: 1,
            failuresByChecker: ["CheckerA": 1, "CheckerB": 1],
            overridesByRiskTier: [.operational: 1, .safety: 1]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(DailySnapshot.self, from: data)
        #expect(decoded.failuresByChecker == ["CheckerA": 1, "CheckerB": 1])
        #expect(decoded.overridesByRiskTier == [.operational: 1, .safety: 1])
    }

    @Test("Corpus scope snapshot")
    func corpusScope() {
        let snapshot = DailySnapshot(
            date: makeDate("2026-04-28"),
            scope: "corpus",
            gateRuns: 50,
            passedRuns: 45,
            failedRuns: 5,
            overrides: 3,
            calibrations: 2,
            failuresByChecker: [:],
            overridesByRiskTier: [:]
        )
        #expect(snapshot.scope == "corpus")
        #expect(abs(snapshot.passRate - 0.9) < 0.001)
    }

    @Test("Equatable: matching snapshots are equal")
    func equatable() {
        let a = makeSnapshot()
        let b = makeSnapshot()
        #expect(a == b)
    }
}
