import Testing
import Foundation
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("TrendComputer")
struct TrendComputerTests {
    @Test("Produces daily pass rate time series")
    func dailyPassRate() {
        let runs = makeDatedRuns(passedByDay: [
            "2026-05-13": [true, true],
            "2026-05-14": [true, false],
            "2026-05-15": [false, false],
        ])
        let trend = TrendComputer.dailyPassRate(from: runs)
        #expect(trend.count == 3)
        #expect(abs(trend[0].value - 1.0) < 1e-6)
        #expect(abs(trend[1].value - 0.5) < 1e-6)
        #expect(abs(trend[2].value - 0.0) < 1e-6)
    }

    @Test("Handles single-run project (no trend)")
    func singleRun() {
        let runs = makeDatedRuns(passedByDay: ["2026-05-15": [true]])
        let trend = TrendComputer.dailyPassRate(from: runs)
        #expect(trend.count == 1)
        #expect(abs(trend[0].value - 1.0) < 1e-6)
    }

    @Test("Duration trend detects slowdowns")
    func durationTrend() {
        let runs = makeDatedRunsWithDurations(durationsByDay: [
            "2026-05-13": [100],
            "2026-05-14": [200],
            "2026-05-15": [400],
        ])
        let trend = TrendComputer.dailyMedianDuration(from: runs)
        #expect(trend.count == 3)
        #expect(trend[0].value < trend[1].value)
        #expect(trend[1].value < trend[2].value)
    }

    @Test("Empty runs produce empty trend")
    func emptyRuns() {
        let trend = TrendComputer.dailyPassRate(from: [])
        #expect(trend.isEmpty)
    }
}

// MARK: - Helpers

private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

private func makeDatedRuns(passedByDay: [String: [Bool]]) -> [TimestampedRun] {
    var runs: [TimestampedRun] = []
    for (dateStr, statuses) in passedByDay.sorted(by: { $0.key < $1.key }) {
        guard let baseDate = dateFormatter.date(from: dateStr) else { continue }
        for (i, passed) in statuses.enumerated() {
            let ts = baseDate.addingTimeInterval(Double(i * 3600))
            runs.append(TimestampedRun(
                metadata: CheckResultMetadata(
                    projectID: "test",
                    timestamp: ts,
                    environment: .local,
                    decisionOwner: "test",
                    results: [CheckResult(checkerId: "safety", status: passed ? .passed : .failed, diagnostics: [], duration: .milliseconds(100))],
                    overrides: [],
                    riskTier: .operational,
                    ethicalFlags: [],
                    consistencyScore: nil
                )
            ))
        }
    }
    return runs.sorted { $0.metadata.timestamp < $1.metadata.timestamp }
}

private func makeDatedRunsWithDurations(durationsByDay: [String: [Int]]) -> [TimestampedRun] {
    var runs: [TimestampedRun] = []
    for (dateStr, durations) in durationsByDay.sorted(by: { $0.key < $1.key }) {
        guard let baseDate = dateFormatter.date(from: dateStr) else { continue }
        for (i, ms) in durations.enumerated() {
            let ts = baseDate.addingTimeInterval(Double(i * 3600))
            runs.append(TimestampedRun(
                metadata: CheckResultMetadata(
                    projectID: "test",
                    timestamp: ts,
                    environment: .local,
                    decisionOwner: "test",
                    results: [CheckResult(checkerId: "safety", status: .passed, diagnostics: [], duration: .milliseconds(ms))],
                    overrides: [],
                    riskTier: .operational,
                    ethicalFlags: [],
                    consistencyScore: nil
                )
            ))
        }
    }
    return runs.sorted { $0.metadata.timestamp < $1.metadata.timestamp }
}
