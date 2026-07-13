// PortfolioSceneTests.swift
// IJSDashboardUI
//
// The portfolio scene builder is a pure Data -> Node function, so it tests by
// Node equality — no running view. This is the same pattern the SwiftGUIKit
// repo's QualityGateDashboard scene tests use.

import Testing
import SwiftGUIKit
import IJSDashboardCore
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
