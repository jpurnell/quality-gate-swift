import Foundation

/// The active view in the dashboard TUI.
public enum DashboardView: Sendable, Equatable {
    case portfolio
    case projectDetail
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
    /// Terminal height used for scroll calculations.
    public var terminalHeight: Int = 24
    /// Sorted project identifiers for the portfolio list.
    public private(set) var projectIDs: [String]

    /// The project ID at the current selection index, or nil if the list is empty.
    public var selectedProjectID: String? {
        guard !projectIDs.isEmpty, selectedIndex < projectIDs.count else { return nil }
        return projectIDs[selectedIndex]
    }

    /// Creates a dashboard state for the given project list.
    public init(projectIDs: [String]) {
        self.projectIDs = projectIDs
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
        case .arrowDown, .scrollDown:
            guard !projectIDs.isEmpty else { return }
            selectedIndex = min(selectedIndex + 1, projectIDs.count - 1)
            ensureSelectionVisible()
        case .arrowUp, .scrollUp:
            selectedIndex = max(selectedIndex - 1, 0)
            ensureSelectionVisible()
        case .enter:
            guard !projectIDs.isEmpty else { return }
            currentView = .projectDetail
            selectedTab = .overview
            scrollOffset = 0
        case .quit, .escape:
            shouldQuit = true
        case .pageDown:
            selectedIndex = min(selectedIndex + terminalHeight / 2, projectIDs.count - 1)
            ensureSelectionVisible()
        case .pageUp:
            selectedIndex = max(selectedIndex - terminalHeight / 2, 0)
            ensureSelectionVisible()
        case .click(let row, _):
            let clickedIndex = row - Self.portfolioHeaderLines - 1 + scrollOffset
            if clickedIndex >= 0, clickedIndex < projectIDs.count {
                selectedIndex = clickedIndex
                currentView = .projectDetail
                selectedTab = .overview
                scrollOffset = 0
            }
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
