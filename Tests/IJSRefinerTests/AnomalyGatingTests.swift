import Testing
import Foundation
@testable import IJSRefiner
import IJSSensor

@Suite("Anomaly Gating Integration")
struct AnomalyGatingTests {

    private func makeDayDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeAnomaly(
        metric: String = "passRate",
        severity: AnomalySeverity = .significant,
        baselineValidity: StatisticalValidity
    ) -> StatisticalAnomaly {
        StatisticalAnomaly(
            metric: metric,
            observedValue: 0.45,
            expectedValue: 0.85,
            zScore: -2.5,
            severity: severity,
            date: makeDayDate("2026-05-01"),
            scope: "test-project",
            direction: .negative,
            baselineValidity: baselineValidity
        )
    }

    @Test("Anomaly with valid baseline gated as confirmed")
    func validBaselineConfirmed() {
        let anomaly = makeAnomaly(baselineValidity: .valid)
        let gated = AnomalyGate.evaluate(
            anomaly: anomaly,
            baselineValidity: anomaly.baselineValidity
        )
        #expect(gated.gatedSeverity == .confirmed)
        #expect(gated.actionability == .investigate)
    }

    @Test("Anomaly with preliminary baseline gated as directional")
    func preliminaryBaselineDirectional() {
        let anomaly = makeAnomaly(baselineValidity: .preliminary)
        let gated = AnomalyGate.evaluate(
            anomaly: anomaly,
            baselineValidity: anomaly.baselineValidity
        )
        #expect(gated.gatedSeverity == .directional)
        #expect(gated.actionability == .monitor)
    }

    @Test("Anomaly with insufficient baseline gated as unreliable")
    func insufficientBaselineUnreliable() {
        let anomaly = makeAnomaly(baselineValidity: .insufficient)
        let gated = AnomalyGate.evaluate(
            anomaly: anomaly,
            baselineValidity: anomaly.baselineValidity
        )
        #expect(gated.gatedSeverity == .unreliable)
        #expect(gated.actionability == .deferAction)
    }

    @Test("Notable severity with valid baseline results in monitor actionability")
    func notableSeverityMonitor() {
        let anomaly = makeAnomaly(severity: .notable, baselineValidity: .valid)
        let gated = AnomalyGate.evaluate(
            anomaly: anomaly,
            baselineValidity: anomaly.baselineValidity
        )
        #expect(gated.gatedSeverity == .confirmed)
        #expect(gated.actionability == .monitor)
    }

    @Test("Explained anomaly overrides actionability to explained")
    func explainedAnomaly() {
        let anomaly = makeAnomaly(baselineValidity: .valid)
        let gated = AnomalyGate.evaluate(
            anomaly: anomaly,
            baselineValidity: anomaly.baselineValidity,
            isExplainedByKnownEvent: true
        )
        #expect(gated.gatedSeverity == .confirmed)
        #expect(gated.actionability == .explained)
    }

    @Test("Extreme severity with preliminary baseline results in monitor")
    func extremePreliminaryMonitor() {
        let anomaly = makeAnomaly(severity: .extreme, baselineValidity: .preliminary)
        let gated = AnomalyGate.evaluate(
            anomaly: anomaly,
            baselineValidity: anomaly.baselineValidity
        )
        #expect(gated.gatedSeverity == .directional)
        #expect(gated.actionability == .monitor)
    }
}
