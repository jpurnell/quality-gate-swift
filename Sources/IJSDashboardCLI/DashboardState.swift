import CorpusService
import Foundation
import IJSSensor

/// A visible row in the portfolio list, either a group header or a project.
public enum PortfolioRow: Sendable, Equatable {
    case group(groupID: String)
    case project(projectID: String)
}

/// The active view in the dashboard TUI.
public enum DashboardView: Sendable, Equatable {
    case portfolio
    case projectDetail
    case groupDetail
    case reviews
}

/// The column by which the portfolio project list is sorted.
public enum SortKey: Sendable, Equatable, CaseIterable {
    case name
    case status
    case passRate
    case runs
}

/// Tabs available in the project detail view.
///
/// The former Overview, Trends, and Status tabs are consolidated into a single
/// scrollable ``DetailTab/summary`` page; ``DetailTab/checkers`` (a long list)
/// stays on its own tab.
public enum DetailTab: Int, Sendable, Equatable, CaseIterable {
    case summary = 0
    case checkers
    case inbox

    /// The label shown for this tab in the detail-view tab bar.
    var label: String {
        switch self {
        case .summary: return "Summary"
        case .checkers: return "Checkers"
        case .inbox: return "Inbox"
        }
    }
}

/// One advisory finding shown in the findings inbox (Phase 3a §7).
public struct InboxRow: Sendable, Equatable {
    /// The rule that produced the finding.
    public let ruleId: String
    /// The finding's message.
    public let message: String
    /// Absolute path of the flagged file.
    public let filePath: String
    /// 1-based flagged line.
    public let lineNumber: Int
    /// Whether the rule has an acknowledgment marker path.
    public let acknowledgeable: Bool

    /// Creates an inbox row.
    public init(ruleId: String, message: String, filePath: String, lineNumber: Int, acknowledgeable: Bool) {
        self.ruleId = ruleId
        self.message = message
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.acknowledgeable = acknowledgeable
    }
}

/// A confirmed acknowledge action, consumed by the app event loop — the
/// reason becomes the marker comment at the flagged location.
public struct AcknowledgeRequest: Sendable, Equatable {
    /// The project whose finding is acknowledged.
    public let projectID: String
    /// Index into the inbox rows at confirmation time.
    public let itemIndex: Int
    /// The human's reason — written into the marker where syntax allows.
    public let reason: String

    /// Creates an acknowledge request.
    public init(projectID: String, itemIndex: Int, reason: String) {
        self.projectID = projectID
        self.itemIndex = itemIndex
        self.reason = reason
    }
}

/// The calibrate wizard's steps, in prompt order (Phase 3a §7).
public enum CalibrateStep: Int, Sendable, Equatable, CaseIterable {
    case ruleId = 0
    case rationale
    case proximateCause
    case rootCause
    case failedStep
    case dissent
    case riskTier

    /// The prompt shown for this step.
    public var prompt: String {
        switch self {
        case .ruleId: return "Rule id (e.g. safety.force-unwrap)"
        case .rationale: return "Override rationale"
        case .proximateCause: return "Proximate cause"
        case .rootCause: return "Root cause (one adjective)"
        case .failedStep: return "Failed 5-step stage (goals/problems/diagnosis/design/doing)"
        case .dissent: return "Red-team dissent — why this might be wrong"
        case .riskTier: return "Risk tier (1-4)"
        }
    }
}

/// A completed calibrate wizard, consumed by the app event loop.
public struct CalibrationRequest: Sendable, Equatable {
    /// The project being calibrated.
    public let projectID: String
    /// The wizard's collected answers, keyed by step.
    public let fields: [CalibrateStep: String]

    /// Creates a calibration request.
    public init(projectID: String, fields: [CalibrateStep: String]) {
        self.projectID = projectID
        self.fields = fields
    }
}

/// What an active text-entry session is collecting.
enum TextEntryPurpose: Sendable, Equatable {
    /// The acknowledge reason for the inbox item at the given index.
    case acknowledgeReason(itemIndex: Int)
    /// One step of the calibrate wizard, with answers collected so far.
    case calibrate(step: CalibrateStep, collected: [CalibrateStep: String])
    /// The rejection reason for the review with the given id.
    case rejectReason(reviewID: String)
}

/// A request to override a project's tier, produced by the Status tab picker.
public struct TierOverrideRequest: Sendable, Equatable {
    /// The project whose tier is being overridden.
    public let projectID: String
    /// The tier to assign as an override.
    public let tier: ProjectTier
}

/// Keyboard and mouse inputs the dashboard state machine handles.
public enum DashboardInput: Sendable {
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case enter
    case escape
    case quit
    case pageUp
    case pageDown
    case scrollUp
    case scrollDown
    case click(row: Int, column: Int)
    case cycleSort
    case reverseSort
    case character(Character)
    case backspace
    case calibrate
    case reviews
    case approve
    case reject
}

/// A confirmed approve/reject on a pending review, consumed by the app
/// event loop (Phase 3b §3). The queue enforces the distinct-second-identity
/// rule; this only carries the human's intent.
public struct ReviewActionRequest: Sendable, Equatable {
    /// What the reviewer decided.
    public enum Action: Sendable, Equatable {
        /// Approve the held judgment.
        case approve
        /// Reject it, with the reviewer's reason.
        case reject
    }

    /// The review being acted on.
    public let reviewID: String
    /// The decision.
    public let action: Action
    /// The rejection reason (nil for approvals).
    public let reason: String?

    /// Creates a review action request.
    public init(reviewID: String, action: Action, reason: String?) {
        self.reviewID = reviewID
        self.action = action
        self.reason = reason
    }
}

/// Navigation state for the interactive TUI dashboard.
public struct DashboardState: Sendable {
    /// Which view is currently displayed.
    public private(set) var currentView: DashboardView = .portfolio
    /// Index of the selected project in the portfolio list.
    public private(set) var selectedIndex: Int = 0
    /// Which tab is active in the project detail view.
    public private(set) var selectedTab: DetailTab = .summary
    /// The project shown in the project-detail view, set on every drill-in.
    ///
    /// Decouples the detail subject from `selectedIndex`: drilling into a group
    /// member (whose row may not exist in the portfolio's `visibleRows` while the
    /// group is collapsed) sets this directly, so the detail view always resolves
    /// a project instead of rendering a blank frame.
    public private(set) var detailProjectID: String?
    /// Whether the user has requested to exit.
    public private(set) var shouldQuit: Bool = false
    /// Vertical scroll offset for content that exceeds terminal height.
    public private(set) var scrollOffset: Int = 0
    /// The column currently used to sort the portfolio project list.
    public private(set) var sortKey: SortKey = .name
    /// Whether the portfolio list is sorted in ascending order.
    public private(set) var sortAscending: Bool = true
    /// The value of sortAscending when the sort key was last set to .name;
    /// used so wrapping a full cycle toggles the name-column direction correctly.
    private var nameBaseAscending: Bool = true
    /// Terminal height used for scroll calculations.
    public var terminalHeight: Int = 24
    /// Whether the portfolio view is currently rendering the compact pulse line.
    /// It adds one chrome row above the table, so click/scroll math must account
    /// for it (see ``portfolioHeaderLines``). Set by the app before handling input.
    public var hasPulseHeader: Bool = false
    /// Sorted project identifiers for the portfolio list.
    public private(set) var projectIDs: [String]
    /// Group definitions from manifest (group name → member project IDs).
    public private(set) var groups: [String: [String]] = [:]
    /// Which groups are currently expanded in the portfolio view.
    public private(set) var expandedGroups: Set<String> = []
    /// The view to return to when pressing Escape from a detail view.
    public private(set) var returnView: DashboardView = .portfolio
    /// Index of the selected member in the group detail view.
    public private(set) var selectedGroupMemberIndex: Int = 0
    /// Whether the tier picker is active in the Status tab.
    public private(set) var tierPickerActive: Bool = false
    /// Index into ProjectTier.allCases for the tier picker selection.
    public private(set) var tierPickerIndex: Int = 0
    /// Set when a tier override is confirmed. The event loop consumes this.
    public private(set) var pendingTierOverride: TierOverrideRequest?
    /// Available pulse labels (date or week), sorted chronologically ascending.
    public private(set) var availableLabels: [String] = []
    /// Index into `availableLabels` for the currently displayed pulse.
    public private(set) var selectedLabelIndex: Int?
    /// Set when the user navigates to a different label; cleared by `clearLabelChanged()`.
    public private(set) var labelChanged: Bool = false
    /// The current project's advisory findings shown on the Inbox tab.
    public private(set) var inboxRows: [InboxRow] = []
    /// Index of the selected inbox row.
    public private(set) var selectedInboxIndex: Int = 0
    /// The active text-entry session, if any (acknowledge reason / calibrate).
    private var textEntrySession: (purpose: TextEntryPurpose, buffer: String)?
    /// Set when an acknowledge is confirmed. The event loop consumes this.
    public private(set) var pendingAcknowledge: AcknowledgeRequest?
    /// Set when the calibrate wizard completes. The event loop consumes this.
    public private(set) var pendingCalibration: CalibrationRequest?
    /// One-line feedback from the last consumed action, rendered by the view.
    public var statusMessage: String?
    /// Pending reviews shown in the Reviews view (Phase 3b §3).
    public private(set) var reviewRows: [PendingReview] = []
    /// Index of the selected review.
    public private(set) var selectedReviewIndex: Int = 0
    /// Set when a reviewer approves/rejects. The event loop consumes this.
    public private(set) var pendingReviewAction: ReviewActionRequest?

    /// Whether a text-entry session owns keyboard input right now.
    public var isTextEntryActive: Bool { textEntrySession != nil }

    /// The text typed so far in the active session (empty when inactive).
    public var textEntryBuffer: String { textEntrySession?.buffer ?? "" }

    /// The calibrate wizard's current step, nil when not calibrating.
    public var calibrateStep: CalibrateStep? {
        if case .calibrate(let step, _) = textEntrySession?.purpose { return step }
        return nil
    }

    /// The prompt for the active text-entry session, for the view.
    public var textEntryPrompt: String? {
        switch textEntrySession?.purpose {
        case .acknowledgeReason: return "Acknowledge reason"
        case .calibrate(let step, _): return step.prompt
        case .rejectReason: return "Rejection reason"
        case nil: return nil
        }
    }

    /// Replaces the inbox rows (set by the app when the detail subject or
    /// its latest run changes) and clamps the selection.
    public mutating func setInboxRows(_ rows: [InboxRow]) {
        inboxRows = rows
        selectedInboxIndex = min(selectedInboxIndex, max(0, rows.count - 1))
    }

    /// Clears a consumed acknowledge request.
    public mutating func clearPendingAcknowledge() { pendingAcknowledge = nil }

    /// Replaces the review rows (set by the app from the review store) and
    /// clamps the selection.
    public mutating func setReviewRows(_ rows: [PendingReview]) {
        reviewRows = rows
        selectedReviewIndex = min(selectedReviewIndex, max(0, rows.count - 1))
    }

    /// Clears a consumed review action.
    public mutating func clearPendingReviewAction() { pendingReviewAction = nil }

    /// Clears a consumed calibration request.
    public mutating func clearPendingCalibration() { pendingCalibration = nil }

    /// The visible rows in the portfolio view, combining groups and projects.
    public var visibleRows: [PortfolioRow] {
        Self.buildVisibleRows(
            projectIDs: projectIDs,
            groups: groups,
            expandedGroups: expandedGroups
        )
    }

    /// The project ID at the current selection index, or nil if selection is on a group row.
    public var selectedProjectID: String? {
        let rows = visibleRows
        guard selectedIndex < rows.count else { return nil }
        if case .project(let projectID) = rows[selectedIndex] {
            return projectID
        }
        return nil
    }

    /// The group ID at the current selection, or nil if selection is not on a group row.
    public var selectedGroupID: String? {
        let rows = visibleRows
        guard selectedIndex < rows.count else { return nil }
        if case .group(let groupID) = rows[selectedIndex] {
            return groupID
        }
        return nil
    }

    /// The label currently selected, or nil if no labels are loaded.
    public var selectedLabel: String? {
        guard let idx = selectedLabelIndex, idx >= 0, idx < availableLabels.count else { return nil }
        return availableLabels[idx]
    }

    /// Creates a dashboard state for the given project list.
    public init(projectIDs: [String]) {
        self.projectIDs = projectIDs
    }

    /// Sets the list of available pulse labels and selects the given label (or latest).
    public mutating func setAvailableLabels(_ labels: [String], selecting label: String? = nil) {
        availableLabels = labels
        if let label, let idx = labels.firstIndex(of: label) {
            selectedLabelIndex = idx
        } else if !labels.isEmpty {
            selectedLabelIndex = labels.count - 1
        } else {
            selectedLabelIndex = nil
        }
    }

    /// Clears the label-changed flag after the caller has reacted to the change.
    public mutating func clearLabelChanged() {
        labelChanged = false
    }

    /// Clears the pending tier override after it has been written to the manifest.
    public mutating func clearPendingTierOverride() {
        pendingTierOverride = nil
    }

    /// Updates the project list, preserving the current selection when possible.
    public mutating func updateProjectIDs(_ newIDs: [String]) {
        let currentRow: PortfolioRow?
        let rows = visibleRows
        if selectedIndex < rows.count {
            currentRow = rows[selectedIndex]
        } else {
            currentRow = nil
        }
        projectIDs = newIDs
        let newRows = visibleRows
        if let currentRow, let idx = newRows.firstIndex(of: currentRow) {
            selectedIndex = idx
        } else {
            selectedIndex = min(selectedIndex, max(0, newRows.count - 1))
        }
    }

    /// Processes a keyboard input, updating view, selection, and tab state.
    public mutating func handleInput(_ input: DashboardInput) {
        // An active text-entry session owns all input (a typed "q" is a
        // character, not quit) — the workbench's one hard routing rule.
        if textEntrySession != nil {
            handleTextEntryInput(input)
            return
        }
        switch currentView {
        case .portfolio:
            handlePortfolioInput(input)
        case .projectDetail:
            handleDetailInput(input)
        case .groupDetail:
            handleGroupDetailInput(input)
        case .reviews:
            handleReviewsInput(input)
        }
    }

    /// The Reviews view (Phase 3b §3): pending judgments awaiting a second
    /// identity. Approve is one keystroke; reject demands a reason.
    private mutating func handleReviewsInput(_ input: DashboardInput) {
        switch input {
        case .escape, .quit:
            currentView = .portfolio
            statusMessage = nil
            scrollOffset = 0
        case .arrowDown:
            guard !reviewRows.isEmpty else { return }
            selectedReviewIndex = min(selectedReviewIndex + 1, reviewRows.count - 1)
        case .arrowUp:
            selectedReviewIndex = max(selectedReviewIndex - 1, 0)
        case .approve:
            guard selectedReviewIndex < reviewRows.count else { return }
            pendingReviewAction = ReviewActionRequest(
                reviewID: reviewRows[selectedReviewIndex].id, action: .approve, reason: nil)
        case .reject:
            guard selectedReviewIndex < reviewRows.count else { return }
            textEntrySession = (.rejectReason(reviewID: reviewRows[selectedReviewIndex].id), "")
        default:
            break
        }
    }

    /// Routes input into the active text-entry session.
    private mutating func handleTextEntryInput(_ input: DashboardInput) {
        guard var session = textEntrySession else { return }
        switch input {
        case .character(let ch):
            session.buffer.append(ch)
            textEntrySession = session
        case .backspace:
            if !session.buffer.isEmpty { session.buffer.removeLast() }
            textEntrySession = session
        case .escape:
            textEntrySession = nil
        case .enter:
            let text = session.buffer.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return } // required — stay on the step
            switch session.purpose {
            case .acknowledgeReason(let itemIndex):
                if let projectID = detailProjectID ?? selectedProjectID {
                    pendingAcknowledge = AcknowledgeRequest(
                        projectID: projectID, itemIndex: itemIndex, reason: text)
                }
                textEntrySession = nil
            case .calibrate(let step, var collected):
                collected[step] = text
                if let next = CalibrateStep(rawValue: step.rawValue + 1) {
                    textEntrySession = (.calibrate(step: next, collected: collected), "")
                } else {
                    if let projectID = detailProjectID ?? selectedProjectID {
                        pendingCalibration = CalibrationRequest(
                            projectID: projectID, fields: collected)
                    }
                    textEntrySession = nil
                }
            case .rejectReason(let reviewID):
                pendingReviewAction = ReviewActionRequest(
                    reviewID: reviewID, action: .reject, reason: text)
                textEntrySession = nil
            }
        default:
            break // arrows etc. have no meaning inside a text field
        }
    }

    /// Clamps scroll offset to the valid range for the given content height.
    public mutating func clampScroll(contentLines: Int) {
        let maxScroll = max(0, contentLines - terminalHeight + 1)
        scrollOffset = min(scrollOffset, maxScroll)
        scrollOffset = max(scrollOffset, 0)
    }

    private mutating func handlePortfolioInput(_ input: DashboardInput) {
        let rows = visibleRows
        switch input {
        case .arrowDown:
            guard !rows.isEmpty else { return }
            selectedIndex = min(selectedIndex + 1, rows.count - 1)
            ensureSelectionVisible()
        case .arrowUp:
            selectedIndex = max(selectedIndex - 1, 0)
            ensureSelectionVisible()
        case .arrowLeft:
            if let groupID = selectedGroupID {
                expandedGroups.remove(groupID)
            } else {
                guard let idx = selectedLabelIndex, idx > 0 else { return }
                selectedLabelIndex = idx - 1
                labelChanged = true
                scrollOffset = 0
            }
        case .arrowRight:
            if let groupID = selectedGroupID {
                expandedGroups.insert(groupID)
            } else {
                guard let idx = selectedLabelIndex, idx < availableLabels.count - 1 else { return }
                selectedLabelIndex = idx + 1
                labelChanged = true
                scrollOffset = 0
            }
        case .scrollDown:
            scrollOffset += 3
        case .scrollUp:
            scrollOffset = max(0, scrollOffset - 3)
        case .enter:
            guard !rows.isEmpty, selectedIndex < rows.count else { return }
            switch rows[selectedIndex] {
            case .group:
                currentView = .groupDetail
                selectedGroupMemberIndex = 0
                scrollOffset = 0
            case .project(let projectID):
                detailProjectID = projectID
                returnView = .portfolio
                currentView = .projectDetail
                selectedTab = .summary
                scrollOffset = 0
            }
        case .quit, .escape:
            shouldQuit = true
        case .pageDown:
            scrollOffset += terminalHeight / 2
        case .pageUp:
            scrollOffset = max(0, scrollOffset - terminalHeight / 2)
        case .click(let row, _):
            let clickedIndex = row - portfolioHeaderLines - 1 + scrollOffset
            if clickedIndex >= 0, clickedIndex < rows.count {
                selectedIndex = clickedIndex
                switch rows[clickedIndex] {
                case .group:
                    currentView = .groupDetail
                    selectedGroupMemberIndex = 0
                    scrollOffset = 0
                case .project(let projectID):
                    detailProjectID = projectID
                    returnView = .portfolio
                    currentView = .projectDetail
                    selectedTab = .summary
                    scrollOffset = 0
                }
            }
        case .reviews:
            currentView = .reviews
            selectedReviewIndex = 0
            scrollOffset = 0
        case .reverseSort:
            sortAscending.toggle()
            if sortKey == .name { nameBaseAscending = sortAscending }
            scrollOffset = 0
        case .cycleSort:
            let allKeys = SortKey.allCases
            guard let currentIdx = allKeys.firstIndex(of: sortKey) else { return }
            let nextIdx = (currentIdx + 1) % allKeys.count
            let nextKey = allKeys[nextIdx]
            if nextKey == sortKey {
                sortAscending.toggle()
                nameBaseAscending = sortAscending
            } else if nextIdx == 0 {
                sortKey = nextKey
                sortAscending = !nameBaseAscending
                nameBaseAscending = sortAscending
            } else {
                sortKey = nextKey
                sortAscending = true
            }
            scrollOffset = 0
        default:
            break
        }
    }

    private mutating func ensureSelectionVisible() {
        let selectedLine = portfolioHeaderLines + selectedIndex
        let visibleBottom = scrollOffset + terminalHeight - 2
        if selectedLine > visibleBottom {
            scrollOffset = selectedLine - terminalHeight + 2
        } else if selectedLine < scrollOffset + portfolioHeaderLines {
            scrollOffset = max(0, selectedLine - portfolioHeaderLines)
        }
        scrollOffset = max(0, scrollOffset)
    }

    private mutating func handleDetailInput(_ input: DashboardInput) {
        // The tier picker only lives on the summary tab, so it owns all input
        // whenever it is active.
        if tierPickerActive {
            handleTierPickerInput(input)
            return
        }
        switch input {
        case .arrowRight:
            switchTab(by: 1)
        case .arrowLeft:
            switchTab(by: -1)
        case .escape, .quit:
            currentView = returnView
            scrollOffset = 0
        case .enter:
            if selectedTab == .summary {
                tierPickerActive = true
            } else if selectedTab == .inbox {
                // Acknowledge-in-place: only rules with a marker path open
                // the reason prompt; the reason becomes the marker comment.
                guard selectedInboxIndex < inboxRows.count,
                      inboxRows[selectedInboxIndex].acknowledgeable else { return }
                textEntrySession = (.acknowledgeReason(itemIndex: selectedInboxIndex), "")
            }
        case .calibrate:
            textEntrySession = (.calibrate(step: .ruleId, collected: [:]), "")
        case .arrowDown:
            if selectedTab == .inbox, !inboxRows.isEmpty {
                selectedInboxIndex = min(selectedInboxIndex + 1, inboxRows.count - 1)
            } else {
                scrollOffset += 1
            }
        case .arrowUp:
            if selectedTab == .inbox, !inboxRows.isEmpty {
                selectedInboxIndex = max(selectedInboxIndex - 1, 0)
            } else {
                scrollOffset = max(0, scrollOffset - 1)
            }
        case .scrollDown:
            scrollOffset += 3
        case .scrollUp:
            scrollOffset = max(0, scrollOffset - 3)
        case .pageDown:
            scrollOffset += terminalHeight / 2
        case .pageUp:
            scrollOffset = max(0, scrollOffset - terminalHeight / 2)
        case .click(let row, let column):
            if let tab = DetailTabBar.tab(atRow: row, column: column, scrollOffset: scrollOffset) {
                selectedTab = tab
                scrollOffset = 0
            }
        default:
            break
        }
    }

    /// Moves the active tab by `delta`, clamped to the tab range (no wrap), and
    /// resets the scroll offset when the tab actually changes. Stale action
    /// feedback does not follow the user to another tab.
    private mutating func switchTab(by delta: Int) {
        statusMessage = nil
        let allTabs = DetailTab.allCases
        let targetIndex = min(max(selectedTab.rawValue + delta, 0), allTabs.count - 1)
        let target = allTabs[targetIndex]
        guard target != selectedTab else { return }
        selectedTab = target
        scrollOffset = 0
    }

    private mutating func handleTierPickerInput(_ input: DashboardInput) {
        let allTiers = ProjectTier.allCases
        switch input {
        case .arrowDown:
            tierPickerIndex = min(tierPickerIndex + 1, allTiers.count - 1)
        case .arrowUp:
            tierPickerIndex = max(tierPickerIndex - 1, 0)
        case .enter:
            if let projectID = detailProjectID ?? selectedProjectID {
                pendingTierOverride = TierOverrideRequest(
                    projectID: projectID,
                    tier: allTiers[tierPickerIndex]
                )
            }
            tierPickerActive = false
        case .escape:
            tierPickerActive = false
        default:
            break
        }
    }

    private mutating func handleGroupDetailInput(_ input: DashboardInput) {
        guard let groupID = selectedGroupID else {
            currentView = .portfolio
            return
        }
        // Order members to match the group detail view, which lists them sorted
        // by projectID; the portfolio sort order must not desync the selection.
        let memberIDs = groups[groupID] ?? []
        let activeMembers = projectIDs.filter { memberIDs.contains($0) }.sorted()

        switch input {
        case .arrowDown:
            guard !activeMembers.isEmpty else { return }
            selectedGroupMemberIndex = min(selectedGroupMemberIndex + 1, activeMembers.count - 1)
        case .arrowUp:
            selectedGroupMemberIndex = max(selectedGroupMemberIndex - 1, 0)
        case .enter, .arrowRight:
            drillIntoGroupMember(activeMembers)
        case .arrowLeft:
            currentView = .portfolio
            scrollOffset = 0
        case .escape, .quit:
            currentView = .portfolio
            scrollOffset = 0
        case .click(let row, _):
            let memberIndex = row - groupDetailHeaderLines - 1 + scrollOffset
            guard memberIndex >= 0, memberIndex < activeMembers.count else { return }
            selectedGroupMemberIndex = memberIndex
            drillIntoGroupMember(activeMembers)
        case .scrollDown:
            scrollOffset += 3
        case .scrollUp:
            scrollOffset = max(0, scrollOffset - 3)
        case .pageDown:
            scrollOffset += terminalHeight / 2
        case .pageUp:
            scrollOffset = max(0, scrollOffset - terminalHeight / 2)
        default:
            break
        }
    }

    /// Opens the selected group member's project detail without moving
    /// `selectedIndex` (which must stay on the group row so returning to the
    /// group detail still resolves `selectedGroupID`).
    private mutating func drillIntoGroupMember(_ activeMembers: [String]) {
        guard !activeMembers.isEmpty, selectedGroupMemberIndex < activeMembers.count else { return }
        detailProjectID = activeMembers[selectedGroupMemberIndex]
        returnView = .groupDetail
        currentView = .projectDetail
        selectedTab = .summary
        scrollOffset = 0
    }

    /// Updates the group definitions from the manifest.
    public mutating func updateGroups(_ newGroups: [String: [String]]) {
        groups = newGroups
    }

    /// Toggles the expanded state of a group.
    public mutating func toggleGroup(_ groupID: String) {
        if expandedGroups.contains(groupID) {
            expandedGroups.remove(groupID)
        } else {
            expandedGroups.insert(groupID)
        }
    }

    /// Builds the visible row list from project IDs, group definitions, and expanded state.
    ///
    /// Groups are sorted alphabetically and appear before ungrouped projects.
    /// Expanded groups show their member projects in the order they appear in `projectIDs`.
    /// Groups with no active members (none in `projectIDs`) are hidden.
    public static func buildVisibleRows(
        projectIDs: [String],
        groups: [String: [String]],
        expandedGroups: Set<String>
    ) -> [PortfolioRow] {
        let projectSet = Set(projectIDs)
        var groupedProjectIDs: Set<String> = []
        var activeGroups: [(name: String, members: [String])] = []

        for (groupName, memberIDs) in groups {
            let activeMembers = memberIDs.filter { projectSet.contains($0) }
            guard !activeMembers.isEmpty else { continue }
            activeGroups.append((name: groupName, members: activeMembers))
            for id in activeMembers {
                groupedProjectIDs.insert(id)
            }
        }

        activeGroups.sort { $0.name < $1.name }

        var rows: [PortfolioRow] = []

        for group in activeGroups {
            rows.append(.group(groupID: group.name))
            if expandedGroups.contains(group.name) {
                let sortedMembers = projectIDs.filter { group.members.contains($0) }
                for memberID in sortedMembers {
                    rows.append(.project(projectID: memberID))
                }
            }
        }

        for projectID in projectIDs where !groupedProjectIDs.contains(projectID) {
            rows.append(.project(projectID: projectID))
        }

        return rows
    }

    /// Number of chrome lines rendered above the first project row in the
    /// portfolio view. Mirrors ``PortfolioTUIView/render(portfolio:projects:allRuns:state:width:pulse:)``:
    /// title rule, blank, status line, (compact pulse line, only when a pulse is
    /// loaded), blank, column header, section rule — so 7 with a pulse, 6 without.
    var portfolioHeaderLines: Int { hasPulseHeader ? 7 : 6 }

    /// Number of chrome lines rendered above the first member row in the group
    /// detail view. Mirrors ``GroupDetailTUIView/render(groupID:memberProjects:groupSnapshots:pulse:state:width:manifest:)``:
    /// title rule, blank, stats line, blank, section rule, column header, section
    /// rule — so the first member row is at line 7. `tabBarOnExpectedLine`'s
    /// group analog (`firstMemberRowLine`) guards this alignment.
    var groupDetailHeaderLines: Int { 7 }
}
