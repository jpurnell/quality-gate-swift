import Testing
import Foundation
@testable import IJSSensor

@Suite("GatedSeverity")
struct GatedSeverityTests {

    @Test("Raw string values match case names")
    func rawValues() {
        #expect(GatedSeverity.confirmed.rawValue == "confirmed")
        #expect(GatedSeverity.directional.rawValue == "directional")
        #expect(GatedSeverity.unreliable.rawValue == "unreliable")
    }

    @Test("Codable round-trip for all cases")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for severity in [GatedSeverity.confirmed, .directional, .unreliable] {
            let data = try encoder.encode(severity)
            let decoded = try decoder.decode(GatedSeverity.self, from: data)
            #expect(decoded == severity)
        }
    }
}

@Suite("Actionability")
struct ActionabilityTests {

    @Test("Raw string values match case names")
    func rawValues() {
        #expect(Actionability.investigate.rawValue == "investigate")
        #expect(Actionability.monitor.rawValue == "monitor")
        #expect(Actionability.deferAction.rawValue == "deferAction")
        #expect(Actionability.explained.rawValue == "explained")
    }

    @Test("Codable round-trip for all cases")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for action in [Actionability.investigate, .monitor, .deferAction, .explained] {
            let data = try encoder.encode(action)
            let decoded = try decoder.decode(Actionability.self, from: data)
            #expect(decoded == action)
        }
    }
}

@Suite("AnomalyGate")
struct AnomalyGateTests {

    private func makeAnomaly(
        severity: AnomalySeverity,
        baselineValidity: StatisticalValidity
    ) -> StatisticalAnomaly {
        StatisticalAnomaly(
            metric: "passRate",
            observedValue: 1.0,
            expectedValue: 0.5,
            zScore: 3.5,
            severity: severity,
            date: Date(),
            scope: "test-project",
            direction: .positive,
            baselineValidity: baselineValidity
        )
    }

    // MARK: - Valid baseline

    @Test("Valid baseline + extreme severity → confirmed / investigate")
    func validExtreme() {
        let anomaly = makeAnomaly(severity: .extreme, baselineValidity: .valid)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .valid)
        #expect(gate.gatedSeverity == .confirmed)
        #expect(gate.actionability == .investigate)
    }

    @Test("Valid baseline + significant severity → confirmed / investigate")
    func validSignificant() {
        let anomaly = makeAnomaly(severity: .significant, baselineValidity: .valid)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .valid)
        #expect(gate.gatedSeverity == .confirmed)
        #expect(gate.actionability == .investigate)
    }

    @Test("Valid baseline + notable severity → confirmed / monitor")
    func validNotable() {
        let anomaly = makeAnomaly(severity: .notable, baselineValidity: .valid)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .valid)
        #expect(gate.gatedSeverity == .confirmed)
        #expect(gate.actionability == .monitor)
    }

    // MARK: - Preliminary baseline

    @Test("Preliminary baseline + extreme severity → directional / monitor")
    func preliminaryExtreme() {
        let anomaly = makeAnomaly(severity: .extreme, baselineValidity: .preliminary)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .preliminary)
        #expect(gate.gatedSeverity == .directional)
        #expect(gate.actionability == .monitor)
    }

    @Test("Preliminary baseline + significant severity → directional / monitor")
    func preliminarySignificant() {
        let anomaly = makeAnomaly(severity: .significant, baselineValidity: .preliminary)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .preliminary)
        #expect(gate.gatedSeverity == .directional)
        #expect(gate.actionability == .monitor)
    }

    @Test("Preliminary baseline + notable severity → directional / deferAction")
    func preliminaryNotable() {
        let anomaly = makeAnomaly(severity: .notable, baselineValidity: .preliminary)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .preliminary)
        #expect(gate.gatedSeverity == .directional)
        #expect(gate.actionability == .deferAction)
    }

    // MARK: - Insufficient baseline

    @Test("Insufficient baseline + extreme severity → unreliable / deferAction")
    func insufficientExtreme() {
        let anomaly = makeAnomaly(severity: .extreme, baselineValidity: .insufficient)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .insufficient)
        #expect(gate.gatedSeverity == .unreliable)
        #expect(gate.actionability == .deferAction)
    }

    @Test("Insufficient baseline + significant severity → unreliable / deferAction")
    func insufficientSignificant() {
        let anomaly = makeAnomaly(severity: .significant, baselineValidity: .insufficient)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .insufficient)
        #expect(gate.gatedSeverity == .unreliable)
        #expect(gate.actionability == .deferAction)
    }

    @Test("Insufficient baseline + notable severity → unreliable / deferAction")
    func insufficientNotable() {
        let anomaly = makeAnomaly(severity: .notable, baselineValidity: .insufficient)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .insufficient)
        #expect(gate.gatedSeverity == .unreliable)
        #expect(gate.actionability == .deferAction)
    }

    // MARK: - Explained override

    @Test("Explained event overrides actionability to explained")
    func explainedOverride() {
        let anomaly = makeAnomaly(severity: .extreme, baselineValidity: .valid)
        let gate = AnomalyGate.evaluate(
            anomaly: anomaly,
            baselineValidity: .valid,
            isExplainedByKnownEvent: true
        )
        #expect(gate.gatedSeverity == .confirmed)
        #expect(gate.actionability == .explained)
    }

    @Test("Explained event overrides even with insufficient baseline")
    func explainedOverrideInsufficient() {
        let anomaly = makeAnomaly(severity: .notable, baselineValidity: .insufficient)
        let gate = AnomalyGate.evaluate(
            anomaly: anomaly,
            baselineValidity: .insufficient,
            isExplainedByKnownEvent: true
        )
        #expect(gate.gatedSeverity == .unreliable)
        #expect(gate.actionability == .explained)
    }

    // MARK: - Codable round-trip

    @Test("AnomalyGate encodes and decodes correctly")
    func codableRoundTrip() throws {
        let anomaly = makeAnomaly(severity: .significant, baselineValidity: .valid)
        let gate = AnomalyGate(
            anomaly: anomaly,
            gatedSeverity: .confirmed,
            actionability: .investigate
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(gate)
        let decoded = try decoder.decode(AnomalyGate.self, from: data)
        #expect(decoded == gate)
    }

    // MARK: - Equatable

    @Test("Identical gates are equal")
    func equatable() {
        let anomaly = makeAnomaly(severity: .extreme, baselineValidity: .valid)
        let gate1 = AnomalyGate(anomaly: anomaly, gatedSeverity: .confirmed, actionability: .investigate)
        let gate2 = AnomalyGate(anomaly: anomaly, gatedSeverity: .confirmed, actionability: .investigate)
        #expect(gate1 == gate2)
    }

    @Test("Gates with different actionability are not equal")
    func notEquatable() {
        let anomaly = makeAnomaly(severity: .extreme, baselineValidity: .valid)
        let gate1 = AnomalyGate(anomaly: anomaly, gatedSeverity: .confirmed, actionability: .investigate)
        let gate2 = AnomalyGate(anomaly: anomaly, gatedSeverity: .confirmed, actionability: .monitor)
        #expect(gate1 != gate2)
    }

    // MARK: - Anomaly preserved

    @Test("Evaluate preserves the original anomaly")
    func preservesAnomaly() {
        let anomaly = makeAnomaly(severity: .significant, baselineValidity: .preliminary)
        let gate = AnomalyGate.evaluate(anomaly: anomaly, baselineValidity: .preliminary)
        #expect(gate.anomaly == anomaly)
    }
}
