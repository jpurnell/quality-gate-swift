// PortfolioSceneTests.swift
// IJSDashboardUI
//
// The portfolio scene builder is a pure Data -> Node function, so it tests by
// Node equality — no running view. This is the same pattern the SwiftGUIKit
// repo's QualityGateDashboard scene tests use.

import Testing
import SwiftGUIKit
import IJSDashboardCore
import CorpusKit
@testable import IJSDashboardUI

@Suite("PortfolioScene")
struct PortfolioSceneTests {

    private let projects = [
        ProjectSummary(projectID: "Alpha", passRate: 0.9, latestPassed: true, runCount: 10),
        ProjectSummary(projectID: "Beta", passRate: 0.5, latestPassed: false, runCount: 4),
    ]
    private let portfolio = PortfolioSummary(totalProjects: 2, passingProjects: 1, failingProjects: 1)

    @Test("the scene is a titled block wrapping a vertical stack")
    func titledBlock() {
        let scene = PortfolioScene.scene(portfolio: portfolio, projects: projects)
        guard case let .block(title, _, _, _, child) = scene else {
            Issue.record("expected a block, got \(scene)"); return
        }
        #expect(title == "IJS Portfolio Dashboard")
        guard case .stack = child else {
            Issue.record("expected the block child to be a stack"); return
        }
    }

    @Test("the projects table has the right columns, ids, and one row per project")
    func projectsTable() {
        let node = PortfolioScene.projectsTable(projects)
        guard case let .table(headers, _, cells, selectedRow, _, sort, _, _, id) = node else {
            Issue.record("expected a table, got \(node)"); return
        }
        #expect(headers == ["Project", "Status", "Pass Rate", "Runs"])
        #expect(id == PortfolioScene.projectsTableID)
        #expect(selectedRow == nil)   // drill-down selection is wired later
        #expect(sort == nil)
        #expect(cells.count == 2)
        #expect(cells[0] == ["Alpha", "pass", "90%", "10"])
        #expect(cells[1] == ["Beta", "fail", "50%", "4"])
    }

    @Test("worst-checkers section lists the top 5, heading first")
    func worstCheckers() {
        let node = PortfolioScene.worstCheckersSection(
            ["unreachable", "doc-coverage", "test-quality", "doc-lint", "swift-version", "idiom"])
        guard case let .stack(_, _, children)? = node else {
            Issue.record("expected a stack, got \(String(describing: node))"); return
        }
        // 1 heading + 5 checkers (the 6th is dropped).
        #expect(children.count == 6)
        guard case let .paragraph(heading, _, _, _) = children[0].node else {
            Issue.record("expected a heading paragraph"); return
        }
        #expect(heading == "Worst Checkers")
        guard case let .paragraph(firstItem, _, _, _) = children[1].node else {
            Issue.record("expected a checker line"); return
        }
        #expect(firstItem.contains("unreachable"))
    }

    @Test("worst-checkers section is nil when there are none")
    func worstCheckersEmpty() {
        #expect(PortfolioScene.worstCheckersSection([]) == nil)
    }

    @Test("the scene includes the worst-checkers section when present")
    func sceneIncludesWorstCheckers() {
        let p = PortfolioSummary(totalProjects: 2, passingProjects: 1, failingProjects: 1,
                                 worstCheckers: ["safety", "logging"])
        let scene = PortfolioScene.scene(portfolio: p, projects: projects)
        guard case let .block(_, _, _, _, child) = scene,
              case let .stack(_, _, children) = child else {
            Issue.record("expected block>stack"); return
        }
        // The last child is the worst-checkers section (a nested stack).
        let hasWorst = children.contains { child in
            if case let .stack(_, _, inner) = child.node,
               case let .paragraph(text, _, _, _) = inner.first?.node {
                return text == "Worst Checkers"
            }
            return false
        }
        #expect(hasWorst)
    }

    @Test("header scene is summary + gauge, no projects table")
    func headerScene() {
        let p = PortfolioSummary(totalProjects: 2, passingProjects: 1, failingProjects: 1)
        guard case let .stack(_, _, headerChildren) = PortfolioScene.headerScene(portfolio: p) else {
            Issue.record("expected header stack"); return
        }
        #expect(!headerChildren.contains { if case .table = $0.node { return true }; return false })
        #expect(headerChildren.contains { if case .gauge = $0.node { return true }; return false })
    }

    // MARK: Pulse analytics (tiers / trajectories / groups)

    @Test("tier counts are best-first, omitting empties")
    func tierCounts() {
        let tiers: [ProjectTier] = [.active, .active, .active, .baseline, .dormant]
        let counts = PulseAnalytics.tierCounts(tiers)
        #expect(counts.map(\.tier) == [.active, .baseline, .dormant])   // active first, atRisk/firstContact absent
        #expect(counts.map(\.count) == [3, 1, 1])
        #expect(PulseAnalytics.tierCounts([]).isEmpty)
    }

    @Test("direction counts are improving/stable/declining in fixed order, zeros included")
    func directionCounts() {
        let directions: [TrajectoryDirection] = [.improving, .stable, .stable, .insufficient]
        let counts = PulseAnalytics.directionCounts(directions)
        #expect(counts.map(\.direction) == [.improving, .stable, .declining])
        #expect(counts.map(\.count) == [1, 2, 0])   // declining present as zero
    }

    @Test("top movers are the steepest by absolute slope, arrowed and rounded")
    func topMovers() {
        let movers = [("Alpha", 0.014), ("Beta", -0.013), ("Gamma", 0.002), ("Flat", 0.0)]
        let top = PulseAnalytics.topMovers(movers, count: 2)
        #expect(top.map(\.id) == ["Alpha", "Beta"])
        #expect(top.map(\.trajectory) == ["↑0.014", "↓0.013"])   // flat excluded
    }

    @Test("pass rate percentage guards zero total")
    func passRatePercent() {
        #expect(PulseAnalytics.passRatePercent(passed: 8, total: 26).rounded() == 31)
        #expect(PulseAnalytics.passRatePercent(passed: 0, total: 0) == 0)
    }

    @Test("worst-checker stats mean the per-project pass rates and carry failure counts")
    func worstCheckerStats() {
        let projects = [
            ProjectSummary(projectID: "A", passRate: 0.9, latestPassed: true,
                           checkerPassRates: ["safety": 0.8], runCount: 5),
            ProjectSummary(projectID: "B", passRate: 0.5, latestPassed: false,
                           checkerPassRates: ["safety": 0.6], runCount: 3),
        ]
        let stats = PulseAnalytics.worstCheckerStats(
            worst: ["safety"], projects: projects, failuresByChecker: ["safety": 12])
        #expect(stats.count == 1)
        #expect(stats[0].checker == "safety")
        #expect(abs(stats[0].passRate - 70) < 0.001)   // mean of 80% and 60%
        #expect(stats[0].failures == 12)
    }

    // MARK: Anomaly formatting

    @Test("anomaly cell: short metric + rounded |z| + direction arrow")
    func anomalyCellText() {
        #expect(AnomalyFormat.metricShort("passRate") == "pass")
        #expect(AnomalyFormat.metricShort("overrideRate") == "ovrd")
        #expect(AnomalyFormat.metricShort("mystery") == "myst")   // prefix(4)
        #expect(AnomalyFormat.cellText(metric: "passRate", zScore: 2.43, isUp: true) == "pass z2.4↑")
        #expect(AnomalyFormat.cellText(metric: "failureRate", zScore: -3.1, isUp: false) == "fail z3.1↓")
    }

    @Test("anomaly is good when pass rate rises or a bad metric falls")
    func anomalyGoodness() {
        #expect(AnomalyFormat.isGood(metric: "passRate", isUp: true))    // pass rate up = good
        #expect(!AnomalyFormat.isGood(metric: "passRate", isUp: false))  // pass rate down = bad
        #expect(AnomalyFormat.isGood(metric: "failureRate", isUp: false))// failures down = good
        #expect(!AnomalyFormat.isGood(metric: "overrideRate", isUp: true))// overrides up = bad
    }

    // MARK: Pulse-derived sections

    @Test("pulse header line carries label, runs, pass%, overrides, consistency")
    func pulseHeader() {
        let node = PortfolioScene.pulseHeaderText(
            label: "2026-07-13", runs: 2379, passRate: 10.5, overrides: 40, consistency: 0.97)
        guard case let .paragraph(text, _, _, _) = node else { Issue.record("not a paragraph"); return }
        #expect(text.contains("2026-07-13"))
        #expect(text.contains("2379 runs"))
        #expect(text.contains("10.5% pass"))
        #expect(text.contains("40 overrides"))
        #expect(text.contains("0.97"))
    }

    @Test("pulse header shows an em dash when consistency is missing")
    func pulseHeaderNoConsistency() {
        let node = PortfolioScene.pulseHeaderText(
            label: "2026-W28", runs: 10, passRate: 100.0, overrides: 0, consistency: nil)
        guard case let .paragraph(text, _, _, _) = node else { Issue.record("not a paragraph"); return }
        #expect(text.contains("Consistency —"))
    }

    @Test("corpus trend is a heading + sparkline; nil when empty")
    func corpusTrend() {
        #expect(PortfolioScene.corpusTrendSection(passRates: []) == nil)
        guard case let .stack(_, _, children)? = PortfolioScene.corpusTrendSection(passRates: [0.9, 0.8, 1.0]) else {
            Issue.record("expected a stack"); return
        }
        guard case let .paragraph(heading, _, _, _) = children[0].node else { Issue.record("no heading"); return }
        #expect(heading == "Corpus Trend (3d)")
        guard case let .sparkline(data, _, _) = children[1].node else { Issue.record("no sparkline"); return }
        #expect(data == [0.9, 0.8, 1.0])
    }

    @Test("violation clusters render as a 4-column table; nil when empty")
    func violationClusters() {
        #expect(PortfolioScene.violationClustersSection([]) == nil)
        let cells = [["complexity.sortInLoop", "?", "7846x/12p", "N/A"]]
        guard case let .stack(_, _, children)? = PortfolioScene.violationClustersSection(cells) else {
            Issue.record("expected a stack"); return
        }
        guard case let .table(headers, _, rows, _, _, _, _, _, _) = children[1].node else {
            Issue.record("no table"); return
        }
        #expect(headers == ["Rule", "Last Wk", "This Wk", "Current"])
        #expect(rows == cells)
    }

    @Test("narrative renders as a heading + paragraph; nil when absent or blank")
    func narrative() {
        #expect(PortfolioScene.narrativeSection(nil) == nil)
        #expect(PortfolioScene.narrativeSection("   \n ") == nil)
        guard case let .stack(_, _, children)? = PortfolioScene.narrativeSection("The portfolio is healthy.") else {
            Issue.record("expected a stack"); return
        }
        guard case let .paragraph(heading, _, _, _) = children[0].node else { Issue.record("no heading"); return }
        #expect(heading == "Narrative")
        guard case let .paragraph(body, _, wrap, _) = children[1].node else { Issue.record("no body"); return }
        #expect(body == "The portfolio is healthy.")
        #expect(wrap)   // narrative wraps
    }

#if canImport(SwiftUI)
    @Test("narrative Markdown splits into headings, rules, and joined paragraphs")
    func narrativeMarkdownBlocks() {
        let md = "Intro line one.\nline two.\n\n---\n\n## Current Health\n\nBody paragraph."
        let blocks = NarrativeMarkdown.blocks(from: md)
        #expect(blocks == [
            .paragraph("Intro line one. line two."),   // soft-wrapped lines joined
            .rule,
            .heading(level: 2, text: "Current Health"),
            .paragraph("Body paragraph."),
        ])
    }

    @Test("narrative Markdown ignores leading/trailing blank lines")
    func narrativeMarkdownBlankLines() {
        #expect(NarrativeMarkdown.blocks(from: "\n\n# Title\n\n") == [.heading(level: 1, text: "Title")])
        #expect(NarrativeMarkdown.blocks(from: "   ").isEmpty)
    }

    @Test("narrative Markdown parses a pipe table, skipping the separator row")
    func narrativeMarkdownTable() {
        let md = """
        ## Current Health at a Glance

        | Dimension | Now |
        |---|---|
        | Passing projects | 52 / 53 (98.1%) |
        | Failing projects | 1 — SwiftCLIKit |
        """
        let blocks = NarrativeMarkdown.blocks(from: md)
        #expect(blocks == [
            .heading(level: 2, text: "Current Health at a Glance"),
            .table(
                headers: ["Dimension", "Now"],
                rows: [["Passing projects", "52 / 53 (98.1%)"], ["Failing projects", "1 — SwiftCLIKit"]]),
        ])
    }
#endif

    @Test("pass-rate percentage rounds to a whole number")
    func percentRounding() {
        #expect(PortfolioScene.percent(0.9) == "90%")
        #expect(PortfolioScene.percent(0.0) == "0%")
        #expect(PortfolioScene.percent(1.0) == "100%")
        #expect(PortfolioScene.percent(0.666) == "67%")   // rounds, not truncates
    }

    @Test("an empty portfolio builds a valid scene with a zero-row table (no divide-by-zero)")
    func emptyPortfolio() {
        let empty = PortfolioSummary(totalProjects: 0, passingProjects: 0, failingProjects: 0)
        let scene = PortfolioScene.scene(portfolio: empty, projects: [])
        let table = PortfolioScene.projectsTable([])
        guard case .block = scene else { Issue.record("expected a block"); return }
        guard case let .table(_, _, cells, _, _, _, _, _, _) = table else {
            Issue.record("expected a table"); return
        }
        #expect(cells.isEmpty)                          // no rows for an empty portfolio
        #expect(PortfolioScene.percent(0.0) == "0%")    // gauge reads 0%, no crash
    }
}
