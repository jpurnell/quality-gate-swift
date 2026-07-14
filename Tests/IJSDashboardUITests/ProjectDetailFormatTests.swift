// ProjectDetailFormatTests.swift
// IJSDashboardUI
//
// The project drill-down's formatting is pure (no SwiftUI, no charting), so it
// tests by value — the same charting-free pattern as PulseAnalyticsTests.

import Testing
import IJSDashboardCore
import CorpusKit
@testable import IJSDashboardUI

@Suite("ProjectDetailFormat")
struct ProjectDetailFormatTests {

    @Test("checker rows sort worst pass rate first, ties by name")
    func checkerRowsSortWorstFirst() {
        let rows = ProjectDetailFormat.checkerRows(
            passRates: ["Recursion": 1.0, "Safety": 0.4, "Concurrency": 0.4],
            latestPassed: ["Recursion": true, "Safety": false, "Concurrency": true])
        #expect(rows.map(\.name) == ["Concurrency", "Safety", "Recursion"])
        #expect(rows[0].latestPassed == true)
        #expect(rows[1].latestPassed == false)
        #expect(rows[2].passPercent == 100)
    }

    @Test("tier labels are human-readable")
    func tierLabels() {
        #expect(ProjectDetailFormat.tierLabel(.active) == "Active")
        #expect(ProjectDetailFormat.tierLabel(.atRisk) == "At Risk")
        #expect(ProjectDetailFormat.tierLabel(.firstContact) == "First Contact")
    }

    @Test("trajectory labels and slope arrows")
    func trajectory() {
        #expect(ProjectDetailFormat.trajectoryLabel(.improving) == "Improving")
        #expect(ProjectDetailFormat.trajectoryLabel(.insufficient) == "Insufficient data")
        #expect(ProjectDetailFormat.slopeArrow(0.2) == "↑")
        #expect(ProjectDetailFormat.slopeArrow(-0.2) == "↓")
        #expect(ProjectDetailFormat.slopeArrow(0) == "→")
    }

    @Test("trend direction compares earliest and latest values")
    func trendDirection() {
        #expect(ProjectDetailFormat.trendDirection([0.5, 0.6, 0.9]) == "↑ Improving")
        #expect(ProjectDetailFormat.trendDirection([0.9, 0.6, 0.5]) == "↓ Declining")
        #expect(ProjectDetailFormat.trendDirection([0.7, 0.5, 0.7]) == "Stable")
        #expect(ProjectDetailFormat.trendDirection([0.7]) == "Stable")
        #expect(ProjectDetailFormat.trendDirection([]) == "Stable")
    }

    @Test("quality score formats to three places, N/A when absent")
    func scoreText() {
        #expect(ProjectDetailFormat.scoreText(0.5) == "0.500")
        #expect(ProjectDetailFormat.scoreText(0.42) == "0.420")
        #expect(ProjectDetailFormat.scoreText(nil) == "N/A")
    }

    @Test("burn-down trail joins the most recent baselined counts")
    func burnDownTrail() {
        let trail = ProjectDetailFormat.burnDownTrail([
            BaselineSnapshot(baselined: 9, expired: 0, newFindings: 0),
            BaselineSnapshot(baselined: 6, expired: 0, newFindings: 0),
            BaselineSnapshot(baselined: 3, expired: 0, newFindings: 0),
        ])
        #expect(trail == "9 → 6 → 3")
        #expect(ProjectDetailFormat.burnDownTrail([]) == "")
    }

    @Test("inbox finding extracts the file name from an absolute path")
    func inboxFileName() {
        let finding = InboxFinding(ruleID: "no-force-unwrap",
                                   message: "force unwrap", filePath: "/a/b/Sources/Foo.swift",
                                   lineNumber: 42, acknowledgeable: true)
        #expect(finding.fileName == "Foo.swift")
        #expect(finding.id == "no-force-unwrap|/a/b/Sources/Foo.swift|42")
    }
}
