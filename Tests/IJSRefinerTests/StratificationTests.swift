import Testing
import Foundation
import QualityGateTypes
@testable import IJSRefiner
import IJSSensor
import IJSAggregator

@Suite("PulseRefiner Stratification")
struct StratificationTests {

    private let writer = TelemetryWriter()

    private func makeDayDate(_ string: String) -> Date {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)!
    }

    private func makeSnapshot(
        date: Date,
        scope: String = "test-project",
        gateRuns: Int = 1,
        passedRuns: Int = 1,
        failedRuns: Int = 0
    ) -> DailySnapshot {
        DailySnapshot(
            date: date,
            scope: scope,
            gateRuns: gateRuns,
            passedRuns: passedRuns,
            failedRuns: failedRuns,
            overrides: 0,
            calibrations: 0,
            failuresByChecker: [:],
            overridesByRiskTier: [:]
        )
    }

    @Test("Project with recent runs classified as active")
    func recentRunsActive() async {
        let refiner = PulseRefiner(writer: writer)
        let windowEnd = makeDayDate("2026-05-07")
        let snapshots: [String: [DailySnapshot]] = [
            "proj-a": [
                makeSnapshot(date: makeDayDate("2026-05-01"), scope: "proj-a", gateRuns: 2),
                makeSnapshot(date: makeDayDate("2026-05-03"), scope: "proj-a", gateRuns: 2),
                makeSnapshot(date: makeDayDate("2026-05-05"), scope: "proj-a", gateRuns: 1),
            ]
        ]
        let tiers = await refiner.classifyProjects(
            projectSnapshots: snapshots, windowEnd: windowEnd
        )
        #expect(tiers["proj-a"] == .active)
    }

    @Test("Project with no runs in 30+ days classified as dormant")
    func noRecentRunsDormant() async {
        let refiner = PulseRefiner(writer: writer)
        let windowEnd = makeDayDate("2026-06-01")
        let snapshots: [String: [DailySnapshot]] = [
            "proj-b": [
                makeSnapshot(date: makeDayDate("2026-04-01"), scope: "proj-b", gateRuns: 5),
            ]
        ]
        let tiers = await refiner.classifyProjects(
            projectSnapshots: snapshots, windowEnd: windowEnd
        )
        #expect(tiers["proj-b"] == .dormant)
    }

    @Test("Project with runs 21-29 days ago classified as atRisk")
    func runsInAtRiskWindow() async {
        let refiner = PulseRefiner(writer: writer)
        let windowEnd = makeDayDate("2026-05-28")
        let snapshots: [String: [DailySnapshot]] = [
            "proj-c": [
                makeSnapshot(date: makeDayDate("2026-05-01"), scope: "proj-c", gateRuns: 3),
                makeSnapshot(date: makeDayDate("2026-05-03"), scope: "proj-c", gateRuns: 2),
                makeSnapshot(date: makeDayDate("2026-05-05"), scope: "proj-c", gateRuns: 1),
            ]
        ]
        let tiers = await refiner.classifyProjects(
            projectSnapshots: snapshots, windowEnd: windowEnd
        )
        #expect(tiers["proj-c"] == .atRisk)
    }

    @Test("Project with fewer than 3 runs classified as firstContact")
    func fewRunsFirstContact() async {
        let refiner = PulseRefiner(writer: writer)
        let windowEnd = makeDayDate("2026-05-07")
        let snapshots: [String: [DailySnapshot]] = [
            "proj-d": [
                makeSnapshot(date: makeDayDate("2026-05-05"), scope: "proj-d", gateRuns: 2),
            ]
        ]
        let tiers = await refiner.classifyProjects(
            projectSnapshots: snapshots, windowEnd: windowEnd
        )
        #expect(tiers["proj-d"] == .firstContact)
    }

    @Test("Group snapshots merge member project data by date")
    func groupSnapshotsMerge() async {
        let refiner = PulseRefiner(writer: writer)
        let date = makeDayDate("2026-05-01")
        let snapshots: [String: [DailySnapshot]] = [
            "proj-a": [DailySnapshot(
                date: date, scope: "proj-a",
                gateRuns: 3, passedRuns: 2, failedRuns: 1,
                overrides: 1, calibrations: 0,
                failuresByChecker: ["SafetyAuditor": 1],
                overridesByRiskTier: [.safety: 1]
            )],
            "proj-b": [DailySnapshot(
                date: date, scope: "proj-b",
                gateRuns: 2, passedRuns: 2, failedRuns: 0,
                overrides: 0, calibrations: 1,
                failuresByChecker: [:],
                overridesByRiskTier: [:]
            )]
        ]
        let groups = ["tools": ["proj-a", "proj-b"]]
        let groupSnaps = await refiner.computeGroupSnapshots(
            projectSnapshots: snapshots, groups: groups
        )
        let toolsSnaps = groupSnaps["tools"]
        #expect(toolsSnaps?.count == 1)
        let merged = toolsSnaps?.first
        #expect(merged?.gateRuns == 5)
        #expect(merged?.passedRuns == 4)
        #expect(merged?.failedRuns == 1)
        #expect(merged?.overrides == 1)
        #expect(merged?.calibrations == 1)
        #expect(merged?.failuresByChecker["SafetyAuditor"] == 1)
        #expect(merged?.overridesByRiskTier[.safety] == 1)
    }
}
