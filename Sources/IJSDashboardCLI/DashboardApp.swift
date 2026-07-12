import Foundation
import IJSAggregator
import IJSDashboardCore
import IJSSensor
import JudgmentWorkbench
#if canImport(os)
import os
#endif
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
                // The compact pulse line adds a chrome row above the table; keep
                // click/scroll hit-testing aligned with what actually renders.
                state.hasPulseHeader = currentPulse != nil

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
                            width: cols,
                            manifest: currentManifest
                        )
                    case .reviews:
                        frame = ReviewsTUIView.render(state: state, width: cols)
                    case .projectDetail:
                        guard let projectID = state.detailProjectID ?? state.selectedProjectID,
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
                    if let input = mapKey(key, textEntryActive: state.isTextEntryActive) {
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

                // The findings inbox tracks the detail subject's latest run
                // (Phase 3a §7). Rebuilt when the subject or its runs change.
                if state.currentView == .projectDetail,
                   let projectID = state.detailProjectID ?? state.selectedProjectID,
                   let latest = currentAllRuns[projectID]?.max(by: { $0.metadata.timestamp < $1.metadata.timestamp }) {
                    let rows = FindingsInbox.items(from: latest.metadata).map { item in
                        InboxRow(
                            ruleId: item.ruleId ?? "(no rule id)",
                            message: item.message,
                            filePath: item.filePath,
                            lineNumber: item.lineNumber,
                            acknowledgeable: item.isAcknowledgeable)
                    }
                    if rows != state.inboxRows {
                        state.setInboxRows(rows)
                        needsRedraw = true
                    }
                }

                // The Reviews view mirrors the shared review store on every
                // pass (cheap read; corpusd will serve this later).
                if state.currentView == .reviews, let corpusPath {
                    let rows = ReviewStore.pending(corpusPath: corpusPath)
                    if rows != state.reviewRows {
                        state.setReviewRows(rows)
                        needsRedraw = true
                    }
                }

                // Approve/reject from the Reviews view — the queue enforces
                // the distinct-second-identity rule; we surface its verdict.
                if let action = state.pendingReviewAction {
                    consumeReviewAction(action, corpusPath: corpusPath, state: &state)
                    state.clearPendingReviewAction()
                    needsRedraw = true
                }

                // Acknowledge-in-place: write the marker at the flagged
                // location. Governed rules (review policy) hold for a second
                // identity instead of writing immediately.
                if let request = state.pendingAcknowledge {
                    consumeAcknowledge(request, allRuns: currentAllRuns, corpusPath: corpusPath, state: &state)
                    state.clearPendingAcknowledge()
                    needsRedraw = true
                }

                // Calibrate wizard completion → a JudgmentCalibration in the
                // corpus, via the same transport every other writer uses.
                if let request = state.pendingCalibration {
                    consumeCalibration(request, corpusPath: corpusPath, state: &state)
                    state.clearPendingCalibration()
                    needsRedraw = true
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

    /// Applies a confirmed acknowledge: writes the marker at the flagged
    /// location via the workbench core — unless the rule is governed by the
    /// review policy, in which case the judgment holds for a distinct second
    /// identity first (Phase 3b §3). Witnesses on escape hatches.
    private static func consumeAcknowledge(
        _ request: AcknowledgeRequest,
        allRuns: [String: [TimestampedRun]],
        corpusPath: String?,
        state: inout DashboardState
    ) {
        guard let latest = allRuns[request.projectID]?
            .max(by: { $0.metadata.timestamp < $1.metadata.timestamp }) else {
            state.statusMessage = "No runs for \(request.projectID) — nothing to acknowledge."
            return
        }
        let items = FindingsInbox.items(from: latest.metadata)
        guard request.itemIndex < items.count else {
            state.statusMessage = "Inbox changed underneath the selection — re-select."
            return
        }
        let item = items[request.itemIndex]

        let decision = GovernedAcknowledge.decide(
            policy: corpusPath.flatMap { ReviewStore.policy(corpusPath: $0) },
            reviews: corpusPath.map { ReviewStore.all(corpusPath: $0) } ?? [],
            ruleId: item.ruleId ?? "",
            reason: request.reason)
        switch decision {
        case .writeMarker:
            do {
                try FindingsInbox.acknowledge(item: item, reason: request.reason)
                let file = (item.filePath as NSString).lastPathComponent
                state.statusMessage = "Marker written at \(file):\(item.lineNumber) — the next gate run records it."
            } catch {
                logger.warning("Acknowledge failed for \(item.ruleId ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
                state.statusMessage = "Acknowledge failed: \(error.localizedDescription)"
            }
        case .submitForReview:
            guard let corpusPath, let ruleId = item.ruleId else {
                state.statusMessage = "Governed rule but no corpus configured — cannot hold for review."
                return
            }
            let owner = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
            state.statusMessage = ReviewStore.submit(
                corpusPath: corpusPath, ruleId: ruleId,
                justification: request.reason, by: owner)
        case .awaitingSecondIdentity:
            state.statusMessage = "Held — awaiting a second identity in the Reviews view (v)."
        case .rejected(let by, let reason):
            state.statusMessage = "Rejected by \(by): \(reason). The finding stands."
        }
    }

    /// Applies an approve/reject from the Reviews view through the queue,
    /// which enforces the distinct-second-identity rule.
    private static func consumeReviewAction(
        _ action: ReviewActionRequest,
        corpusPath: String?,
        state: inout DashboardState
    ) {
        guard let corpusPath else {
            state.statusMessage = "No corpus configured — reviews unavailable."
            return
        }
        let reviewer = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
        state.statusMessage = ReviewStore.apply(
            action, corpusPath: corpusPath, reviewer: reviewer)
        state.setReviewRows(ReviewStore.pending(corpusPath: corpusPath))
    }

    /// Writes the calibrate wizard's result to the corpus as a
    /// JudgmentCalibration — the MCP tool's exact artifact, human-reached.
    private static func consumeCalibration(
        _ request: CalibrationRequest,
        corpusPath: String?,
        state: inout DashboardState
    ) {
        guard let corpusPath else {
            state.statusMessage = "No corpus configured — calibration not recorded."
            return
        }
        let fields = request.fields
        guard let ruleId = fields[.ruleId], let rationale = fields[.rationale],
              let proximate = fields[.proximateCause], let root = fields[.rootCause],
              let stepText = fields[.failedStep], let dissent = fields[.dissent] else {
            state.statusMessage = "Calibration incomplete — discarded."
            return
        }
        guard let failedStep = FiveStepStage(rawValue: stepText.lowercased()) else {
            state.statusMessage = "Unknown 5-step stage '\(stepText)' — use goals/problems/diagnosis/design/doing."
            return
        }
        let tierRaw = Int(fields[.riskTier] ?? "") ?? 2
        let riskTier = RiskTier(rawValue: tierRaw) ?? .operational
        let owner = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
        let calibration = JudgmentCalibration(
            date: Date(),
            decisionOwner: owner,
            practitioner: owner,
            riskTier: riskTier,
            rootCauseAnalysis: RootCauseAnalysis(
                proximateCause: proximate,
                chainOfInquiry: [rationale],
                rootCause: root,
                failedStep: failedStep,
                isRecurringPattern: false
            ),
            redTeamDissent: dissent,
            proposedPolicyUpdate: nil,
            pulseContribution: "Override of \(ruleId) at tier \(tierRaw): \(rationale)"
        )
        let metadata = CheckResultMetadata(
            projectID: request.projectID,
            timestamp: calibration.date,
            environment: .local,
            decisionOwner: owner,
            results: [],
            overrides: [],
            riskTier: riskTier,
            ethicalFlags: [],
            consistencyScore: nil
        )
        let corpus = CorpusPath(basePath: corpusPath, projectID: request.projectID)
        let writer = DirectCorpusTransport()
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = Mutex<String?>(nil)
        Task {
            do {
                try await writer.write(metadata: metadata, calibrations: [calibration], to: corpus)
                outcome.withLock { $0 = "Calibration recorded for \(ruleId) (tier \(tierRaw))." }
            } catch {
                logger.warning("Calibration write failed: \(error.localizedDescription, privacy: .public)")
                outcome.withLock { $0 = "Calibration write failed: \(error.localizedDescription)" }
            }
            semaphore.signal()
        }
        semaphore.wait()
        state.statusMessage = outcome.withLock { $0 }
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
        var orientationCards: [String: ModuleOrientationCard] = [:]
        do {
            orientationCards = PortfolioOrientation.cards(
                from: try reader.loadAllOrientationReports(),
                knownProjects: Set(freshRuns.keys)
            )
        } catch {
            logger.warning("Failed to load orientation reports: \(error.localizedDescription, privacy: .public)")
        }
        let freshProjects = freshRuns.map { (projectID, runs) in
            let lifecycle = manifest.lifecycle(for: projectID)
            return ProjectSummary.compute(
                projectID: projectID,
                from: runs,
                lifecycle: lifecycle,
                orientation: orientationCards[projectID]
            )
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

    private static func mapKey(_ key: Key, textEntryActive: Bool) -> DashboardInput? {
        // A text-entry session (acknowledge reason, calibrate wizard) takes
        // every printable key as content — "q" must type, not quit.
        if textEntryActive {
            switch key {
            case .character(let ch):
                return .character(ch)
            case .backspace:
                return .backspace
            case .enter:
                return .enter
            case .escape:
                return .escape
            default:
                return nil
            }
        }
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
        case .character("c"), .character("C"):
            return .calibrate
        case .character("v"), .character("V"):
            return .reviews
        case .character("a"), .character("A"):
            return .approve
        case .character("x"), .character("X"):
            return .reject
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
