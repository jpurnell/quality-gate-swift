import Foundation
import Testing
@testable import IJSAggregator
@testable import IJSDashboardCore
import QualityGateTypes

/// Phase 2 §4b — the tripwire in the dashboard's data model.
///
/// `ProjectSummary.compute` runs the writer census over every loaded run so
/// the standing multi-writer warning is available to any renderer.
@Suite("ProjectSummary writer census")
struct WriterCensusSummaryTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRun(owner: String, host: String?, daysAgo: Double) -> TimestampedRun {
        TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: base.addingTimeInterval(-daysAgo * 86_400),
                environment: .local,
                decisionOwner: owner,
                results: [CheckResult(checkerId: "safety", status: .passed, diagnostics: [], duration: .milliseconds(1))],
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil,
                host: host
            )
        )
    }

    @Test("a single-writer project computes an untripped census")
    func singleWriterUntripped() {
        let summary = ProjectSummary.compute(
            projectID: "test",
            from: [
                makeRun(owner: "jpurnell", host: "studio.local", daysAgo: 1),
                makeRun(owner: "jpurnell", host: "roseclub.local", daysAgo: 2),
            ],
            censusDate: base)
        let census = summary.writerCensus
        #expect(census?.tripped == false)
        #expect(census?.persons == ["jpurnell"])
        #expect(census?.machines.count == 2)
    }

    @Test("a second person trips the census and carries the standing warning")
    func secondPersonTrips() {
        let summary = ProjectSummary.compute(
            projectID: "test",
            from: [
                makeRun(owner: "jpurnell", host: "studio.local", daysAgo: 1),
                makeRun(owner: "contributor", host: "their-mac.local", daysAgo: 3),
            ],
            censusDate: base)
        let census = summary.writerCensus
        #expect(census?.tripped == true)
        #expect(census?.persons == ["contributor", "jpurnell"])
        #expect(census?.standingWarning?.contains("Phase 3") == true)
    }

    @Test("advisory runs never count toward the gate pass rate")
    func advisoryRunsExcluded() {
        let passing = TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: base.addingTimeInterval(-86_400),
                environment: .local,
                decisionOwner: "jpurnell",
                results: [CheckResult(checkerId: "safety", status: .passed, diagnostics: [], duration: .milliseconds(1))],
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil,
                gateMode: .advisory
            )
        )
        let failing = TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: base.addingTimeInterval(-2 * 86_400),
                environment: .local,
                decisionOwner: "jpurnell",
                results: [CheckResult(checkerId: "safety", status: .failed, diagnostics: [], duration: .milliseconds(1))],
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
        let summary = ProjectSummary.compute(
            projectID: "test", from: [passing, failing], censusDate: base)
        // The advisory pass is invisible to gate stats: one standard run,
        // and it failed.
        #expect(summary.runCount == 1)
        #expect(summary.latestPassed == false)
        #expect(abs(summary.passRate - 0.0) < 1e-6)
    }

    @Test("an old second writer outside the window stays quiet")
    func expiredWriterQuiet() {
        let summary = ProjectSummary.compute(
            projectID: "test",
            from: [
                makeRun(owner: "jpurnell", host: "studio.local", daysAgo: 1),
                makeRun(owner: "long-gone", host: "old.local", daysAgo: 60),
            ],
            censusDate: base)
        #expect(summary.writerCensus?.tripped == false)
    }
}
