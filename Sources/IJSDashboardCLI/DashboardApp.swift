import Foundation
import IJSAggregator
import IJSDashboardCore
import IJSSensor
import os
import SwiftCLIKit
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let dashboardShouldExit = Atomic<Bool>(false)

/// Interactive TUI event loop for the IJS dashboard.
public enum DashboardApp: Sendable {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DashboardApp")
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
        manifest: CorpusManifest = CorpusManifest(),
        corpusPath: String? = nil,
        initialWeek: String? = nil
    ) {
        var currentPortfolio = portfolio
        var sortedProjects = projects.sorted { $0.projectID < $1.projectID }
        var currentAllRuns = allRuns
        var currentPulse = pulse
        var currentManifest = manifest
        let activeIDs = sortedProjects.filter { $0.lifecycle == .active }.map(\.projectID)
        var state = DashboardState(projectIDs: activeIDs)
        state.updateGroups(currentManifest.groups)
        var lastReloadTime = Date.now

        if let corpusReader {
            let labels = corpusReader.listAvailableLabels()
            state.setAvailableLabels(labels, selecting: initialWeek)
            if let initialWeek, let loaded = corpusReader.loadPulse(label: initialWeek) {
                currentPulse = loaded
            }
        }

        setvbuf(stdout, nil, _IONBF, 0)
        dashboardShouldExit.store(false, ordering: .relaxed)

        signal(SIGINT) { _ in
            let restore = CursorControl.show + MouseMode.disable
            let bytes = Array(restore.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                guard let ptr = buffer.baseAddress else { return }
                _ = write(1, ptr, buffer.count)
            }
            dashboardShouldExit.store(true, ordering: .releasing)
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

        while !dashboardShouldExit.load(ordering: .acquiring) && !state.shouldQuit && !eofReached {
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
                    case .groupDetail:
                        guard let groupID = state.selectedGroupID else {
                            frame = ""
                            break
                        }
                        let memberIDs = currentManifest.groups[groupID] ?? []
                        let memberProjects = sortedProjects.filter { memberIDs.contains($0.projectID) }
                        let snapshots = currentPulse?.groupSnapshots?[groupID]
                        frame = GroupDetailTUIView.render(
                            groupID: groupID,
                            memberProjects: memberProjects,
                            groupSnapshots: snapshots,
                            pulse: currentPulse,
                            state: state,
                            width: cols
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
                            width: cols,
                            pulse: currentPulse,
                            manifest: currentManifest
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

                if let override = state.pendingTierOverride {
                    let existing = currentManifest.projects[override.projectID]
                    currentManifest.projects[override.projectID] = CorpusManifestEntry(
                        lifecycle: existing?.lifecycle ?? .active,
                        reason: existing?.reason,
                        changedAt: existing?.changedAt ?? Date(),
                        tierOverride: override.tier
                    )
                    if let corpusPath {
                        let manifestURL = URL(fileURLWithPath: "\(corpusPath)/manifest.yml") // SAFETY: writes to configured corpus path
                        do {
                            try currentManifest.save(to: manifestURL)
                        } catch {
                            logger.warning("Failed to save manifest to \(manifestURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    state.clearPendingTierOverride()
                    needsRedraw = true
                }

                if state.labelChanged, let corpusReader,
                   let selectedLabel = state.selectedLabel {
                    currentPulse = corpusReader.loadPulse(label: selectedLabel)
                    state.clearLabelChanged()
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
                        pulse: &currentPulse,
                        manifest: &currentManifest
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
        pulse: inout InstitutionalPulse?,
        manifest: inout CorpusManifest
    ) {
        let freshRuns: [String: [TimestampedRun]]
        do {
            freshRuns = try reader.loadAll()
        } catch {
            logger.warning("Failed to reload corpus data: \(error.localizedDescription, privacy: .public)")
            return
        }
        allRuns = freshRuns
        do {
            manifest = try reader.loadManifest()
        } catch {
            logger.warning("Failed to reload manifest: \(error.localizedDescription, privacy: .public)")
            manifest = CorpusManifest()
        }
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
        state.updateGroups(manifest.groups)

        let currentLabel = state.selectedLabel
        let labels = reader.listAvailableLabels()
        state.setAvailableLabels(labels, selecting: currentLabel)

        if let selectedLabel = state.selectedLabel {
            pulse = reader.loadPulse(label: selectedLabel)
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
