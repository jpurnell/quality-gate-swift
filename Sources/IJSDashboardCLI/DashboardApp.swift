import Foundation
import IJSAggregator
import IJSDashboardCore
import IJSSensor
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

    private static let reloadIntervalSeconds: Double = 30

    /// Launches the full-screen interactive dashboard with keyboard and mouse navigation.
    /// When a `corpusReader` is provided, data reloads every 30 seconds.
    /// - Parameter initialWeek: If set, start on this week label instead of the latest.
    public static func run(
        portfolio: PortfolioSummary,
        projects: [ProjectSummary],
        allRuns: [String: [TimestampedRun]],
        corpusReader: CorpusReader? = nil,
        pulse: InstitutionalPulse? = nil,
        initialWeek: String? = nil
    ) {
        var currentPortfolio = portfolio
        var sortedProjects = projects.sorted { $0.projectID < $1.projectID }
        var currentAllRuns = allRuns
        var currentPulse = pulse
        let activeIDs = sortedProjects.filter { $0.lifecycle == .active }.map(\.projectID)
        var state = DashboardState(projectIDs: activeIDs)
        var lastReloadTime = Date.now

        if let corpusReader {
            let weeks = corpusReader.listAvailableWeeks()
            state.setAvailableWeeks(weeks, selecting: initialWeek)
            if let initialWeek, let loaded = corpusReader.loadPulse(weekLabel: initialWeek) {
                currentPulse = loaded
            }
        }

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
        var needsRedraw = true
        var eofReached = false

        while !dashboardShouldExit && !state.shouldQuit && !eofReached {
            autoreleasepool {
                let size = TerminalSize.current()
                let cols = max(size.columns, 20)
                let rows = size.rows

                if cols != lastWidth || rows != lastHeight {
                    lastContent = ""
                    lastWidth = cols
                    lastHeight = rows
                    needsRedraw = true
                }

                state.terminalHeight = rows

                if needsRedraw {
                    let frame: String
                    switch state.currentView {
                    case .portfolio:
                        frame = PortfolioTUIView.render(
                            portfolio: currentPortfolio,
                            projects: sortedProjects,
                            allRuns: currentAllRuns,
                            state: state,
                            width: cols,
                            pulse: currentPulse
                        )
                    case .projectDetail:
                        guard let projectID = state.selectedProjectID,
                              let project = sortedProjects.first(where: { $0.projectID == projectID }) else {
                            frame = ""
                            break
                        }
                        let runs = currentAllRuns[projectID] ?? []
                        let trends = TrendComputer.dailyPassRate(from: runs)
                        frame = ProjectDetailTUIView.render(
                            project: project,
                            trends: trends,
                            runs: runs,
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

                    needsRedraw = false
                }

                if stdinReady(timeoutMs: 500) {
                    guard let key = reader.readKey() else {
                        eofReached = true
                        return
                    }
                    if let input = mapKey(key) {
                        let previousSortKey = state.sortKey
                        let previousSortAsc = state.sortAscending
                        state.handleInput(input)
                        needsRedraw = true

                        if state.sortKey != previousSortKey || state.sortAscending != previousSortAsc {
                            let ids = PortfolioTUIView.sortedActiveIDs(
                                from: sortedProjects,
                                sortKey: state.sortKey,
                                sortAscending: state.sortAscending
                            )
                            state.updateProjectIDs(ids)
                        }
                    }
                }

                if state.weekChanged, let corpusReader,
                   let weekLabel = state.selectedWeekLabel {
                    currentPulse = corpusReader.loadPulse(weekLabel: weekLabel)
                    state.clearWeekChanged()
                    lastContent = ""
                    needsRedraw = true
                }

                if let corpusReader,
                   Date.now.timeIntervalSince(lastReloadTime) >= reloadIntervalSeconds {
                    reloadData(
                        reader: corpusReader,
                        portfolio: &currentPortfolio,
                        projects: &sortedProjects,
                        allRuns: &currentAllRuns,
                        state: &state,
                        pulse: &currentPulse
                    )
                    lastReloadTime = Date.now
                    lastContent = ""
                    needsRedraw = true
                }
            }
        }

        writeToStdout(mouseDisableSequence)
        writeToStdout(CursorControl.show)
        _ = screen
    }

    private static func stdinReady(timeoutMs: Int32) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, timeoutMs) > 0 && (pfd.revents & Int16(POLLIN)) != 0
        #else
        return true
        #endif
    }

    private static func reloadData(
        reader: CorpusReader,
        portfolio: inout PortfolioSummary,
        projects: inout [ProjectSummary],
        allRuns: inout [String: [TimestampedRun]],
        state: inout DashboardState,
        pulse: inout InstitutionalPulse?
    ) {
        guard let freshRuns = try? reader.loadAll() else { return } // silent: reload failure is non-fatal; dashboard continues with stale data
        allRuns = freshRuns
        let manifest = (try? reader.loadManifest()) ?? CorpusManifest() // silent: manifest is optional; missing file treated as all-active
        let freshProjects = freshRuns.map { (projectID, runs) in
            let lifecycle = manifest.lifecycle(for: projectID)
            return ProjectSummary.compute(projectID: projectID, from: runs, lifecycle: lifecycle)
        }.sorted { $0.projectID < $1.projectID }
        projects = freshProjects
        portfolio = PortfolioSummary.compute(from: freshProjects)
        let sortedIDs = PortfolioTUIView.sortedActiveIDs(
            from: freshProjects,
            sortKey: state.sortKey,
            sortAscending: state.sortAscending
        )
        state.updateProjectIDs(sortedIDs)

        let currentWeek = state.selectedWeekLabel
        let weeks = reader.listAvailableWeeks()
        state.setAvailableWeeks(weeks, selecting: currentWeek)

        if let weekLabel = state.selectedWeekLabel {
            pulse = reader.loadPulse(weekLabel: weekLabel)
        } else {
            pulse = reader.loadLatestPulse()
        }
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
        case .character("s"):
            return .cycleSort
        case .character("S"):
            return .reverseSort
        case .character("r"), .character("R"):
            return .reverseSort
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
