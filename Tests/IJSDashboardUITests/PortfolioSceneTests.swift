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
