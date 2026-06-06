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
}

/// The column by which the portfolio project list is sorted.
public enum SortKey: Sendable, Equatable, CaseIterable {
    case name
    case status
    case passRate
    case runs
}

/// Tabs available in the project detail view.
public enum DetailTab: Int, Sendable, Equatable, CaseIterable {
    case overview = 0
    case checkers
    case trends
    case status
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
    case tab
    case backtab
    case quit
    case pageUp
    case pageDown
    case scrollUp
    case scrollDown
    case click(row: Int, column: Int)
    case cycleSort
    case reverseSort
}

/// Navigation state for the interactive TUI dashboard.
public struct DashboardState: Sendable {
    /// Which view is currently displayed.
    public private(set) var currentView: DashboardView = .portfolio
    /// Index of the selected project in the portfolio list.
    public private(set) var selectedIndex: Int = 0
    /// Which tab is active in the project detail view.
    public private(set) var selectedTab: DetailTab = .overview
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
        switch currentView {
        case .portfolio:
            handlePortfolioInput(input)
        case .projectDetail:
            handleDetailInput(input)
        case .groupDetail:
            handleGroupDetailInput(input)
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
            case .project:
                returnView = .portfolio
                currentView = .projectDetail
                selectedTab = .overview
                scrollOffset = 0
            }
        case .quit, .escape:
            shouldQuit = true
        case .pageDown:
            scrollOffset += terminalHeight / 2
        case .pageUp:
            scrollOffset = max(0, scrollOffset - terminalHeight / 2)
        case .click(let row, _):
            let clickedIndex = row - Self.portfolioHeaderLines - 1 + scrollOffset
            if clickedIndex >= 0, clickedIndex < rows.count {
                selectedIndex = clickedIndex
                switch rows[clickedIndex] {
                case .group:
                    currentView = .groupDetail
                    selectedGroupMemberIndex = 0
                    scrollOffset = 0
                case .project:
                    returnView = .portfolio
                    currentView = .projectDetail
                    selectedTab = .overview
                    scrollOffset = 0
                }
            }
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
        let selectedLine = Self.portfolioHeaderLines + selectedIndex
        let visibleBottom = scrollOffset + terminalHeight - 2
        if selectedLine > visibleBottom {
            scrollOffset = selectedLine - terminalHeight + 2
        } else if selectedLine < scrollOffset + Self.portfolioHeaderLines {
            scrollOffset = max(0, selectedLine - Self.portfolioHeaderLines)
        }
        scrollOffset = max(0, scrollOffset)
    }

    private mutating func handleDetailInput(_ input: DashboardInput) {
        if selectedTab == .status && tierPickerActive {
            handleTierPickerInput(input)
            return
        }
        switch input {
        case .tab:
            let allTabs = DetailTab.allCases
            let nextRaw = (selectedTab.rawValue + 1) % allTabs.count
            selectedTab = allTabs[nextRaw]
            scrollOffset = 0
        case .backtab:
            let allTabs = DetailTab.allCases
            let prevRaw = (selectedTab.rawValue - 1 + allTabs.count) % allTabs.count
            selectedTab = allTabs[prevRaw]
            scrollOffset = 0
        case .escape, .quit:
            currentView = returnView
            scrollOffset = 0
        case .enter:
            if selectedTab == .status {
                tierPickerActive = true
            }
        case .arrowDown:
            scrollOffset += 1
        case .arrowUp:
            scrollOffset = max(0, scrollOffset - 1)
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

    private mutating func handleTierPickerInput(_ input: DashboardInput) {
        let allTiers = ProjectTier.allCases
        switch input {
        case .arrowDown:
            tierPickerIndex = min(tierPickerIndex + 1, allTiers.count - 1)
        case .arrowUp:
            tierPickerIndex = max(tierPickerIndex - 1, 0)
        case .enter:
            if let projectID = selectedProjectID {
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
        let memberIDs = groups[groupID] ?? []
        let activeMembers = projectIDs.filter { memberIDs.contains($0) }

        switch input {
        case .arrowDown:
            guard !activeMembers.isEmpty else { return }
            selectedGroupMemberIndex = min(selectedGroupMemberIndex + 1, activeMembers.count - 1)
        case .arrowUp:
            selectedGroupMemberIndex = max(selectedGroupMemberIndex - 1, 0)
        case .enter:
            guard !activeMembers.isEmpty, selectedGroupMemberIndex < activeMembers.count else { return }
            let memberID = activeMembers[selectedGroupMemberIndex]
            if let projectIndex = visibleRows.firstIndex(of: .project(projectID: memberID)) {
                selectedIndex = projectIndex
            }
            returnView = .groupDetail
            currentView = .projectDetail
            selectedTab = .overview
            scrollOffset = 0
        case .escape, .quit:
            currentView = .portfolio
            scrollOffset = 0
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

    /// Number of fixed header lines before project rows in the portfolio view.
    static let portfolioHeaderLines = 6
}
