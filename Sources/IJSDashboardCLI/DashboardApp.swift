import Foundation
import IJSDashboardCore
import SwiftCLIKit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Justification: signal handlers cannot capture context; single-writer (signal handler) / single-reader (main thread) pattern is safe
nonisolated(unsafe) private var dashboardShouldExit = false

/// Interactive TUI event loop for the IJS dashboard.
public enum DashboardApp: Sendable {

    private static let mouseEnableSequence = MouseMode.enable
    private static let mouseDisableSequence = MouseMode.disable

    /// Launches the full-screen interactive dashboard with keyboard and mouse navigation.
    public static func run(
        portfolio: PortfolioSummary,
        projects: [ProjectSummary],
        allRuns: [String: [TimestampedRun]]
    ) {
        let sortedProjects = projects.sorted { $0.projectID < $1.projectID }
        let projectIDs = sortedProjects.map(\.projectID)
        var state = DashboardState(projectIDs: projectIDs)

        setvbuf(stdout, nil, _IONBF, 0)
        dashboardShouldExit = false

        signal(SIGINT) { _ in
            let restore = CursorControl.show + MouseMode.disable
            let bytes = Array(restore.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                guard let ptr = buffer.baseAddress else { return }
                _ = write(1, ptr, buffer.count)
            }
            dashboardShouldExit = true
        }

        let screen = AlternateScreen()
        writeToStdout(CursorControl.hide)
        writeToStdout(mouseEnableSequence)

        let terminal = RawTerminal()
        let reader = KeyReader(terminal: terminal)

        var lastContent = ""
        var lastWidth = 0
        var lastHeight = 0

        while !dashboardShouldExit && !state.shouldQuit {
            let size = TerminalSize.current()
            let cols = max(size.columns, 20)
            let rows = size.rows

            if cols != lastWidth || rows != lastHeight {
                lastContent = ""
                lastWidth = cols
                lastHeight = rows
            }

            state.terminalHeight = rows

            let frame: String
            switch state.currentView {
            case .portfolio:
                frame = PortfolioTUIView.render(
                    portfolio: portfolio,
                    projects: sortedProjects,
                    state: state,
                    width: cols
                )
            case .projectDetail:
                guard let projectID = state.selectedProjectID,
                      let project = sortedProjects.first(where: { $0.projectID == projectID }) else {
                    frame = ""
                    break
                }
                let runs = allRuns[projectID] ?? []
                let trends = TrendComputer.dailyPassRate(from: runs)
                frame = ProjectDetailTUIView.render(
                    project: project,
                    trends: trends,
                    state: state,
                    width: cols
                )
            }

            var allLines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while allLines.last?.isEmpty == true { allLines.removeLast() }

            state.clampScroll(contentLines: allLines.count)

            var output = ANSICodes.clearScreen
            let visibleCount = min(rows, allLines.count - state.scrollOffset)
            for i in 0..<visibleCount {
                let line = allLines[state.scrollOffset + i]
                let truncated = ANSIStringMetrics.truncateVisible(line, to: cols)
                output += "\u{001B}[\(i + 1);1H" + truncated
            }

            let maxScroll = allLines.count - rows
            if maxScroll > 0 {
                let pct = Int((Double(state.scrollOffset) / Double(maxScroll) * 100).rounded())
                let indicator = ANSICodes.dim + "[\(pct)%]" + ANSICodes.reset
                let indicatorCol = max(1, cols - 5)
                output += "\u{001B}[\(rows);\(indicatorCol)H" + indicator
            }

            if output != lastContent {
                writeToStdout(output)
                lastContent = output
            }

            guard let key = reader.readKey() else { break }
            if let input = mapKey(key) {
                state.handleInput(input)
            }
        }

        writeToStdout(mouseDisableSequence)
        writeToStdout(CursorControl.show)
        _ = screen
    }

    private static func writeToStdout(_ string: String) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let ptr = buffer.baseAddress else { return }
            _ = write(1, ptr, buffer.count)
        }
    }

    private static func mapKey(_ key: Key) -> DashboardInput? {
        switch key {
        case .arrowUp:
            return .arrowUp
        case .arrowDown:
            return .arrowDown
        case .arrowLeft:
            return .arrowLeft
        case .arrowRight:
            return .arrowRight
        case .enter:
            return .enter
        case .escape:
            return .escape
        case .tab:
            return .tab
        case .backtab:
            return .backtab
        case .pageUp:
            return .pageUp
        case .pageDown:
            return .pageDown
        case .character("q"), .character("Q"):
            return .quit
        case .mouse(let event):
            return mapMouse(event)
        default:
            return nil
        }
    }

    private static func mapMouse(_ event: MouseEvent) -> DashboardInput? {
        switch event.button {
        case .scrollUp:
            return .scrollUp
        case .scrollDown:
            return .scrollDown
        case .left:
            return .click(row: event.row, column: event.column)
        default:
            return nil
        }
    }
}
