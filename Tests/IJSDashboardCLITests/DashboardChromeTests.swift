import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes
import SwiftCLIKit

@Suite("Dashboard Chrome — copy-friendly borders")
struct DashboardChromeTests {

    /// U+2502 BOX DRAWINGS LIGHT VERTICAL — the character that must no longer
    /// appear as a left/right frame edge, since it corrupts copied narrative text.
    private static let verticalBar = "\u{2502}"

    // MARK: - DashboardChrome helpers

    @Test("sectionRule is a full-width horizontal rule with no vertical edges")
    func sectionRuleHasNoVerticals() {
        let rule = DashboardChrome.sectionRule(width: 40)
        #expect(!rule.contains(Self.verticalBar))
        #expect(rule.allSatisfy { String($0) == "\u{2500}" })
        #expect(ANSIStringMetrics.visibleLength(rule) == 40)
    }

    @Test("titleRule embeds the title and stays within width")
    func titleRuleEmbedsTitle() {
        let rule = DashboardChrome.titleRule(" IJS Portfolio Dashboard ", width: 60)
        #expect(rule.contains("IJS Portfolio Dashboard"))
        #expect(!rule.contains(Self.verticalBar))
        #expect(ANSIStringMetrics.visibleLength(rule) == 60)
    }

    @Test("titleRule truncates an over-wide title to fit")
    func titleRuleTruncates() {
        let rule = DashboardChrome.titleRule(String(repeating: "x", count: 200), width: 20)
        #expect(ANSIStringMetrics.visibleLength(rule) <= 20)
    }

    @Test("contentRow emits content without vertical edges or trailing padding")
    func contentRowNoVerticals() {
        let row = DashboardChrome.contentRow("  hello world", width: 80)
        #expect(!row.contains(Self.verticalBar))
        #expect(row == "  hello world")
    }

    @Test("contentRow truncates content wider than the terminal")
    func contentRowTruncates() {
        let row = DashboardChrome.contentRow(String(repeating: "a", count: 120), width: 80)
        #expect(ANSIStringMetrics.visibleLength(row) <= 80)
    }

    // MARK: - Rendered views contain no vertical frame edges

    @Test("Portfolio view renders no vertical bar characters")
    func portfolioNoVerticalBars() {
        let projects = [
            makeProjectSummary(id: "alpha", passRate: 1.0),
            makeProjectSummary(id: "beta", passRate: 0.8),
        ]
        let portfolio = PortfolioSummary.compute(from: projects)
        let state = DashboardState(projectIDs: ["alpha", "beta"])
        let pulse = makePulseWithNarrative(
            "This week the corpus held steady. Pass rates climbed across BusinessMath and Harbor while VaultMCP regressed. Watch doc-coverage closely."
        )
        let output = PortfolioTUIView.render(
            portfolio: portfolio,
            projects: projects,
            allRuns: [:],
            state: state,
            width: 80,
            pulse: pulse
        )
        #expect(!output.contains(Self.verticalBar))
        // Narrative content must survive so it can be copied cleanly.
        #expect(output.contains("doc-coverage closely"))
    }

    @Test("Project detail view renders no vertical bar characters")
    func detailNoVerticalBars() {
        let summary = makeProjectSummary(id: "quality-gate-swift", passRate: 0.9)
        var state = DashboardState(projectIDs: ["quality-gate-swift"])
        state.handleInput(.enter)
        let output = ProjectDetailTUIView.render(
            project: summary,
            trends: [],
            runs: [],
            state: state,
            width: 80
        )
        #expect(!output.contains(Self.verticalBar))
    }

    @Test("Group detail view renders no vertical bar characters")
    func groupNoVerticalBars() {
        let projects = [
            makeProjectSummary(id: "appA", passRate: 0.8),
            makeProjectSummary(id: "appB", passRate: 0.6),
        ]
        var state = DashboardState(projectIDs: ["appA", "appB"])
        state.updateGroups(["Harbor": ["appA", "appB"]])
        let output = GroupDetailTUIView.render(
            groupID: "Harbor",
            memberProjects: projects,
            groupSnapshots: nil,
            pulse: nil,
            state: state,
            width: 80
        )
        #expect(!output.contains(Self.verticalBar))
    }

    @Test("PulseSectionRenderer narrative lines contain no vertical bars")
    func pulseNarrativeNoVerticalBars() {
        let lines = PulseSectionRenderer.renderNarrative(
            "First line of the weekly narrative.\nSecond line with more detail about the corpus.",
            width: 80
        )
        for line in lines {
            #expect(!line.contains(Self.verticalBar))
        }
    }
}

// MARK: - Test Helpers

private func makePulseWithNarrative(_ narrative: String) -> InstitutionalPulse {
    let stats = PulseStatistics(
        totalGateRuns: 100,
        passedRuns: 60,
        failedRuns: 40,
        totalOverrides: 0,
        totalCalibrations: 0,
        overridesByRiskTier: [:],
        failuresByChecker: [:],
        rootCauseDistribution: [:],
        failedStepDistribution: [:],
        meanConsistencyScore: 0.85,
        corpusTrends: [],
        projectTrends: [:],
        anomalies: [],
        corpusSnapshots: [],
        projectSnapshots: [:]
    )
    return InstitutionalPulse(
        windowStart: Date(timeIntervalSince1970: 1747267200),
        windowEnd: Date(timeIntervalSince1970: 1747872000),
        weekLabel: "W20",
        projects: ["alpha", "beta"],
        statistics: stats,
        violationClusters: [],
        proposedPolicyUpdates: [],
        calibrationSummaries: [],
        narrative: narrative,
        generatedAt: Date(timeIntervalSince1970: 1747872000)
    )
}

private func makeProjectSummary(
    id: String,
    passRate: Double,
    runCount: Int = 10
) -> ProjectSummary {
    let latestPassed = passRate > 0.5
    let passingRunCount = Int((Double(runCount) * passRate).rounded())
    let runs = (0..<runCount).map { i in
        let runPasses = latestPassed
            ? i >= (runCount - passingRunCount)
            : i < passingRunCount
        let results = [
            CheckResult(
                checkerId: "safety",
                status: runPasses ? .passed : .failed,
                diagnostics: [],
                duration: .milliseconds(100)
            ),
        ]
        return TimestampedRun(
            metadata: CheckResultMetadata(
                projectID: id,
                timestamp: Date(timeIntervalSince1970: Double(1747267200 + i * 3600)),
                environment: .local,
                decisionOwner: "test",
                results: results,
                overrides: [],
                riskTier: .operational,
                ethicalFlags: [],
                consistencyScore: nil
            )
        )
    }
    return ProjectSummary.compute(projectID: id, from: runs, lifecycle: .active)
}
