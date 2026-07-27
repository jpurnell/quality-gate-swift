import Testing
import Foundation
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("DailyRuns.authoritativePerDay")
struct DailyRunsTests {
    @Test("Collapses multiple runs per day to one per day")
    func collapsesPerDay() {
        let runs = [
            run(day: "2026-05-13", hour: 8, checkers: ["safety": false]),
            run(day: "2026-05-13", hour: 9, checkers: ["safety": true]),
            run(day: "2026-05-14", hour: 8, checkers: ["safety": true]),
        ]
        let authoritative = DailyRuns.authoritativePerDay(runs)
        #expect(authoritative.count == 2)
    }

    @Test("Latest full standard run of a day is authoritative")
    func latestFullStandardWins() {
        // Fail at 08:00, pass at 09:00 after a fix — the day's authoritative
        // assessment is the later, passing run.
        let runs = [
            run(day: "2026-05-13", hour: 8, checkers: ["safety": false]),
            run(day: "2026-05-13", hour: 9, checkers: ["safety": true]),
        ]
        let authoritative = DailyRuns.authoritativePerDay(runs)
        #expect(authoritative.count == 1)
        #expect(authoritative[0].metadata.results.allSatisfy { $0.status.isPassing })
    }

    @Test("A full run outranks a later subset run in the same day")
    func fullOutranksLaterSubset() {
        // A full failing run, then a targeted subset re-run that passes: the
        // subset is not a fresh whole-gate assessment, so the full run stays
        // authoritative for the day.
        let runs = [
            run(day: "2026-05-13", hour: 8, checkers: ["safety": false], scope: .full),
            run(day: "2026-05-13", hour: 9, checkers: ["safety": true],
                scope: .subset(checkers: ["safety"])),
        ]
        let authoritative = DailyRuns.authoritativePerDay(runs)
        #expect(authoritative.count == 1)
        #expect(authoritative[0].metadata.runScope == .full)
        #expect(authoritative[0].metadata.results.contains { !$0.status.isPassing })
    }

    @Test("A day with only subset runs falls back to its latest run")
    func subsetOnlyFallsBack() {
        let runs = [
            run(day: "2026-05-13", hour: 8, checkers: ["safety": false],
                scope: .subset(checkers: ["safety"])),
            run(day: "2026-05-13", hour: 9, checkers: ["safety": true],
                scope: .subset(checkers: ["safety"])),
        ]
        let authoritative = DailyRuns.authoritativePerDay(runs)
        #expect(authoritative.count == 1)
        // No full run exists, so the latest run of the day is used.
        #expect(authoritative[0].metadata.results.allSatisfy { $0.status.isPassing })
    }

    @Test("Result is sorted ascending by timestamp")
    func sortedAscending() {
        let runs = [
            run(day: "2026-05-15", hour: 8, checkers: ["safety": true]),
            run(day: "2026-05-13", hour: 8, checkers: ["safety": true]),
            run(day: "2026-05-14", hour: 8, checkers: ["safety": true]),
        ]
        let authoritative = DailyRuns.authoritativePerDay(runs)
        #expect(authoritative.count == 3)
        #expect(authoritative[0].metadata.timestamp < authoritative[1].metadata.timestamp)
        #expect(authoritative[1].metadata.timestamp < authoritative[2].metadata.timestamp)
    }

    @Test("Empty input yields empty output")
    func emptyInput() {
        #expect(DailyRuns.authoritativePerDay([]).isEmpty)
    }
}

// MARK: - Helpers

private let utcDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private func run(
    day: String,
    hour: Int,
    checkers: [String: Bool],
    scope: RunScope = .full,
    gateMode: GateMode = .standard
) -> TimestampedRun {
    let base = utcDayFormatter.date(from: day) ?? Date(timeIntervalSince1970: 0)
    let ts = base.addingTimeInterval(Double(hour) * 3600)
    let results = checkers.map { id, passed in
        CheckResult(checkerId: id, status: passed ? .passed : .failed,
                    diagnostics: [], duration: .milliseconds(100))
    }
    return TimestampedRun(
        metadata: CheckResultMetadata(
            projectID: "test",
            timestamp: ts,
            environment: .local,
            decisionOwner: "test",
            results: results,
            overrides: [],
            riskTier: .operational,
            ethicalFlags: [],
            consistencyScore: nil,
            runScope: scope,
            gateMode: gateMode
        )
    )
}
