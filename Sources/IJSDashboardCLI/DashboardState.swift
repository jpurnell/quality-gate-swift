import Foundation

/// The active view in the dashboard TUI.
public enum DashboardView: Sendable, Equatable {
    case portfolio
    case projectDetail
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
    /// Available pulse labels (date or week), sorted chronologically ascending.
    public private(set) var availableLabels: [String] = []
    /// Index into `availableLabels` for the currently displayed pulse.
    public private(set) var selectedLabelIndex: Int?
    /// Set when the user navigates to a different label; cleared by `clearLabelChanged()`.
    public private(set) var labelChanged: Bool = false

    /// The project ID at the current selection index, or nil if the list is empty.
    public var selectedProjectID: String? {
        guard !projectIDs.isEmpty, selectedIndex < projectIDs.count else { return nil }
        return projectIDs[selectedIndex]
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

    /// Updates the project list, preserving the current selection when possible.
    public mutating func updateProjectIDs(_ newIDs: [String]) {
        let currentID = selectedProjectID
        projectIDs = newIDs
        if let currentID, let idx = newIDs.firstIndex(of: currentID) {
            selectedIndex = idx
        } else {
            selectedIndex = min(selectedIndex, max(0, newIDs.count - 1))
        }
    }

    /// Processes a keyboard input, updating view, selection, and tab state.
    public mutating func handleInput(_ input: DashboardInput) {
        switch currentView {
        case .portfolio:
            handlePortfolioInput(input)
        case .projectDetail:
            handleDetailInput(input)
        }
    }

    /// Clamps scroll offset to the valid range for the given content height.
    public mutating func clampScroll(contentLines: Int) {
        let maxScroll = max(0, contentLines - terminalHeight + 1)
        scrollOffset = min(scrollOffset, maxScroll)
        scrollOffset = max(scrollOffset, 0)
    }

    private mutating func handlePortfolioInput(_ input: DashboardInput) {
        switch input {
        case .arrowDown:
            guard !projectIDs.isEmpty else { return }
            selectedIndex = min(selectedIndex + 1, projectIDs.count - 1)
            ensureSelectionVisible()
        case .arrowUp:
            selectedIndex = max(selectedIndex - 1, 0)
            ensureSelectionVisible()
        case .arrowLeft:
            guard let idx = selectedLabelIndex, idx > 0 else { return }
            selectedLabelIndex = idx - 1
            labelChanged = true
            scrollOffset = 0
        case .arrowRight:
            guard let idx = selectedLabelIndex, idx < availableLabels.count - 1 else { return }
            selectedLabelIndex = idx + 1
            labelChanged = true
            scrollOffset = 0
        case .scrollDown:
            scrollOffset += 3
        case .scrollUp:
            scrollOffset = max(0, scrollOffset - 3)
        case .enter:
            guard !projectIDs.isEmpty else { return }
            currentView = .projectDetail
            selectedTab = .overview
            scrollOffset = 0
        case .quit, .escape:
            shouldQuit = true
        case .pageDown:
            scrollOffset += terminalHeight / 2
        case .pageUp:
            scrollOffset = max(0, scrollOffset - terminalHeight / 2)
        case .click(let row, _):
            let clickedIndex = row - Self.portfolioHeaderLines - 1 + scrollOffset
            if clickedIndex >= 0, clickedIndex < projectIDs.count {
                selectedIndex = clickedIndex
                currentView = .projectDetail
                selectedTab = .overview
                scrollOffset = 0
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
                // Only reachable when allCases has a single element; toggle direction in place.
                sortAscending.toggle()
                nameBaseAscending = sortAscending
            } else if nextIdx == 0 {
                // Wrapped back to the first key: flip the baseline direction so each complete
                // cycle through all sort keys alternates ascending/descending for the name column.
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
            currentView = .portfolio
            scrollOffset = 0
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

    /// Number of fixed header lines before project rows in the portfolio view.
    static let portfolioHeaderLines = 6
}
