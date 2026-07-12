import Foundation
import Testing
@testable import IJSAggregator
@testable import IJSDashboardCore
import QualityGateTypes

/// Phase 4c §3 — the decaying baseline's dashboard feed.
///
/// Runs that applied a ledger stamp `baseline` counts into their metadata;
/// `ProjectSummary.compute` collects them chronologically so renderers can
/// show debt as a burn-down. Debts trend to zero or they expire loudly —
/// nothing is silent, everything ages.
@Suite("ProjectSummary baseline burn-down")
struct BaselineBurnDownTests {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRun(daysAgo: Double, baseline: BaselineSnapshot?) -> TimestampedRun {
        TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: "test",
                timestamp: base.addingTimeInterval(-daysAgo * 86_400),
                environment: .local,
                decisionOwner: "jpurnell",
                results: [CheckResult(checkerId: "safety", status: .passed, diagnostics: [], duration: .milliseconds(1))],
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil,
                baseline: baseline
            )
        )
    }

    @Test("baselined runs collect chronologically as the burn-down series")
    func burnDownSeries() {
        let summary = ProjectSummary.compute(
            projectID: "test",
            from: [
                makeRun(daysAgo: 1, baseline: BaselineSnapshot(baselined: 31, expired: 2, newFindings: 0)),
                makeRun(daysAgo: 5, baseline: BaselineSnapshot(baselined: 42, expired: 0, newFindings: 1)),
                makeRun(daysAgo: 3, baseline: BaselineSnapshot(baselined: 38, expired: 1, newFindings: 0)),
            ],
            censusDate: base)
        #expect(summary.baselineBurnDown.map(\.baselined) == [42, 38, 31])
        #expect(summary.latestBaseline == BaselineSnapshot(baselined: 31, expired: 2, newFindings: 0))
    }

    @Test("runs without a ledger contribute nothing — no ledger, no burn-down")
    func noLedgerNoSeries() {
        let summary = ProjectSummary.compute(
            projectID: "test",
            from: [
                makeRun(daysAgo: 2, baseline: nil),
                makeRun(daysAgo: 1, baseline: nil),
            ],
            censusDate: base)
        #expect(summary.baselineBurnDown.isEmpty)
        #expect(summary.latestBaseline == nil)
    }

    @Test("ledgered and unledgered runs mix: the series keeps only the ledgered ones")
    func mixedRuns() {
        let summary = ProjectSummary.compute(
            projectID: "test",
            from: [
                makeRun(daysAgo: 4, baseline: BaselineSnapshot(baselined: 10, expired: 0, newFindings: 0)),
                makeRun(daysAgo: 2, baseline: nil),
                makeRun(daysAgo: 1, baseline: BaselineSnapshot(baselined: 7, expired: 3, newFindings: 2)),
            ],
            censusDate: base)
        #expect(summary.baselineBurnDown.map(\.baselined) == [10, 7])
        #expect(summary.latestBaseline?.expired == 3)
        #expect(summary.latestBaseline?.newFindings == 2)
    }
}
