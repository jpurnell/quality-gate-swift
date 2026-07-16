// main.swift
// ijs-dashboard-preview
//
// A headless preview harness: renders the native portfolio dashboard to a PNG
// from realistic sample data, so the SwiftUI surface can be eyeballed without a
// live display or a corpus. Usage: ijs-dashboard-preview <output.png>

import Foundation
import IJSDashboardCore
import IJSDashboardUI
import SwiftGUIKit
import SwiftCLIKit

let projects: [ProjectSummary] = [
    ProjectSummary(projectID: "quality-gate-swift", passRate: 0.94, latestPassed: true, latestFullPassed: true, runCount: 142),
    ProjectSummary(projectID: "SwiftCLIKit", passRate: 1.0, latestPassed: true, latestFullPassed: true, runCount: 38),
    ProjectSummary(projectID: "org-judgement-system", passRate: 0.71, latestPassed: false, runCount: 56),
    // Green from a targeted --check re-run, not yet confirmed by a full gate — renders ✓*.
    ProjectSummary(projectID: "BusinessMath", passRate: 0.88, latestPassed: true, latestFullPassed: false, runCount: 27),
    ProjectSummary(projectID: "swift-vigil", passRate: 0.63, latestPassed: false, runCount: 19),
]
let portfolio = PortfolioSummary(totalProjects: 5, passingProjects: 3, failingProjects: 2)

// `--text` prints the terminal render of the scene (headless-reliable); the
// default opens the actual native window with sample data (no corpus needed).
if CommandLine.arguments.contains("--text") {
    let scene = PortfolioScene.scene(portfolio: portfolio, projects: projects)
    let width = 74, height = 15
    var frame = Frame(buffer: CellBuffer(width: width, height: height),
                      rect: Rect(x: 0, y: 0, width: width, height: height))
    CellRenderer(resolver: TerminalTokenResolver(theme: .dark), context: .terminalTruecolor)
        .render(scene, into: &frame)
    let buffer = frame.cellBuffer
    var text = ""
    for y in 0..<height {
        for x in 0..<width { text.append(buffer[x, y].character) }
        text.append("\n")
    }
    FileHandle.standardOutput.write(Data(text.utf8))
} else {
    IJSDashboardUI.launch(portfolio: portfolio, projects: projects)   // opens a window, blocks
}
