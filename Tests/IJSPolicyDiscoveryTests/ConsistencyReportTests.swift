import Testing
import Foundation
@testable import IJSPolicyDiscovery
import IJSSensor

@Suite("ConsistencyReport")
struct ConsistencyReportTests {

    private func makeDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeFinding(
        ruleId: String = "concurrency.unchecked-sendable",
        matchType: ConsistencyMatchType = .clusterMatch,
        isRecurring: Bool = true
    ) -> ConsistencyFinding {
        ConsistencyFinding(
            ruleId: ruleId,
            checkerId: "ConcurrencyAuditor",
            matchType: matchType,
            clusterRiskWeight: 0.3,
            historicalOccurrences: 5,
            isRecurringInPulse: isRecurring,
            explanation: "Test finding"
        )
    }

    private func makeReport(
        findings: [ConsistencyFinding] = [],
        consistencyScore: Double = 1.0,
        baselineValidity: StatisticalValidity = .valid
    ) -> ConsistencyReport {
        ConsistencyReport(
            projectID: "test-project",
            timestamp: makeDate("2026-04-28"),
            pulseWeekLabel: "2026-W18",
            findings: findings,
            consistencyScore: consistencyScore,
            baselineValidity: baselineValidity
        )
    }

    @Test("Init stores all fields")
    func initStoresFields() {
        let report = makeReport(consistencyScore: 0.85, baselineValidity: .preliminary)
        #expect(report.projectID == "test-project")
        #expect(report.pulseWeekLabel == "2026-W18")
        #expect(abs(report.consistencyScore - 0.85) < 1e-6)
        #expect(report.baselineValidity == .preliminary)
    }

    @Test("findingsCount returns correct count")
    func findingsCount() {
        let report = makeReport(findings: [makeFinding(), makeFinding(ruleId: "safety.force-unwrap")])
        #expect(report.findingsCount == 2)
    }

    @Test("findingsCount is zero for empty report")
    func findingsCountEmpty() {
        let report = makeReport()
        #expect(report.findingsCount == 0)
    }

    @Test("recurringFindings filters correctly")
    func recurringFindings() {
        let recurring = makeFinding(isRecurring: true)
        let nonRecurring = makeFinding(ruleId: "safety.force-unwrap", isRecurring: false)
        let report = makeReport(findings: [recurring, nonRecurring])
        #expect(report.recurringFindings.count == 1)
        #expect(report.recurringFindings.first?.ruleId == "concurrency.unchecked-sendable")
    }

    @Test("findingCountsByType groups correctly")
    func findingCountsByType() {
        let findings = [
            makeFinding(matchType: .clusterMatch),
            makeFinding(ruleId: "safety.force-unwrap", matchType: .clusterMatch),
            makeFinding(ruleId: "pointer.escape", matchType: .anomalyPattern),
        ]
        let report = makeReport(findings: findings)
        let counts = report.findingCountsByType
        #expect(counts[.clusterMatch] == 2)
        #expect(counts[.anomalyPattern] == 1)
        #expect(counts[.unaddressedPolicy] == nil)
    }

    @Test("recurringFraction computes correctly")
    func recurringFraction() {
        let findings = [
            makeFinding(isRecurring: true),
            makeFinding(ruleId: "a", isRecurring: true),
            makeFinding(ruleId: "b", isRecurring: false),
            makeFinding(ruleId: "c", isRecurring: false),
        ]
        let report = makeReport(findings: findings)
        #expect(abs(report.recurringFraction - 0.5) < 1e-6)
    }

    @Test("recurringFraction is zero for empty findings")
    func recurringFractionEmpty() {
        let report = makeReport()
        #expect(abs(report.recurringFraction - 0.0) < 1e-6)
    }

    @Test("recurringFraction is 1.0 when all recurring")
    func recurringFractionAll() {
        let findings = [
            makeFinding(isRecurring: true),
            makeFinding(ruleId: "a", isRecurring: true),
        ]
        let report = makeReport(findings: findings)
        #expect(abs(report.recurringFraction - 1.0) < 1e-6)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let findings = [makeFinding(), makeFinding(ruleId: "safety.force-unwrap", matchType: .anomalyPattern)]
        let report = makeReport(findings: findings, consistencyScore: 0.7, baselineValidity: .preliminary)
        let data = try encoder.encode(report)
        let decoded = try decoder.decode(ConsistencyReport.self, from: data)
        #expect(decoded == report)
    }

    @Test("Equatable: same fields are equal")
    func equalitySame() {
        let report = makeReport(consistencyScore: 0.85)
        let other = makeReport(consistencyScore: 0.85)
        #expect(report == other)
    }

    @Test("Equatable: different scores are not equal")
    func equalityDifferentScore() {
        let a = makeReport(consistencyScore: 0.85)
        let b = makeReport(consistencyScore: 0.70)
        #expect(a != b)
    }
}
