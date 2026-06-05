import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
@testable import IJSSensor
import QualityGateTypes

@Suite("DashboardState")
struct DashboardStateTests {

    // MARK: - Initial State

    @Test("Initial state is portfolio view with selection at zero")
    func initialState() {
        let state = DashboardState(projectIDs: ["alpha", "beta", "gamma"])
        #expect(state.currentView == .portfolio)
        #expect(state.selectedIndex == 0)
    }

    @Test("Initial state with empty projects")
    func emptyProjects() {
        let state = DashboardState(projectIDs: [])
        #expect(state.currentView == .portfolio)
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Portfolio Navigation

    @Test("Arrow down increments selection")
    func arrowDown() {
        var state = DashboardState(projectIDs: ["a", "b", "c"])
        state.handleInput(.arrowDown)
        #expect(state.selectedIndex == 1)
        state.handleInput(.arrowDown)
        #expect(state.selectedIndex == 2)
    }

    @Test("Arrow down clamps at last project")
    func arrowDownClamp() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown)
        #expect(state.selectedIndex == 1)
    }

    @Test("Arrow up decrements selection")
    func arrowUp() {
        var state = DashboardState(projectIDs: ["a", "b", "c"])
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown)
        state.handleInput(.arrowUp)
        #expect(state.selectedIndex == 1)
    }

    @Test("Arrow up clamps at zero")
    func arrowUpClamp() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.handleInput(.arrowUp)
        #expect(state.selectedIndex == 0)
    }

    // MARK: - View Switching

    @Test("Enter switches to project detail view")
    func enterToDetail() {
        var state = DashboardState(projectIDs: ["alpha", "beta"])
        state.handleInput(.arrowDown)
        state.handleInput(.enter)
        #expect(state.currentView == .projectDetail)
        #expect(state.selectedProjectID == "beta")
    }

    @Test("Enter on empty project list does nothing")
    func enterEmpty() {
        var state = DashboardState(projectIDs: [])
        state.handleInput(.enter)
        #expect(state.currentView == .portfolio)
    }

    @Test("Escape returns to portfolio from detail")
    func escapeToPortfolio() {
        var state = DashboardState(projectIDs: ["alpha"])
        state.handleInput(.enter)
        #expect(state.currentView == .projectDetail)
        state.handleInput(.escape)
        #expect(state.currentView == .portfolio)
    }

    @Test("Q key in detail returns to portfolio")
    func qToPortfolio() {
        var state = DashboardState(projectIDs: ["alpha"])
        state.handleInput(.enter)
        state.handleInput(.quit)
        #expect(state.currentView == .portfolio)
    }

    // MARK: - Tab Navigation

    @Test("Tab cycles through detail tabs")
    func tabCycle() {
        var state = DashboardState(projectIDs: ["alpha"])
        state.handleInput(.enter)
        #expect(state.selectedTab == .overview)
        state.handleInput(.tab)
        #expect(state.selectedTab == .checkers)
        state.handleInput(.tab)
        #expect(state.selectedTab == .trends)
        state.handleInput(.tab)
        #expect(state.selectedTab == .overview)
    }

    @Test("Backtab cycles tabs backwards")
    func backtabCycle() {
        var state = DashboardState(projectIDs: ["alpha"])
        state.handleInput(.enter)
        #expect(state.selectedTab == .overview)
        state.handleInput(.backtab)
        #expect(state.selectedTab == .trends)
    }

    // MARK: - Scroll

    @Test("Mouse scroll down in portfolio scrolls viewport")
    func scrollDownMovesViewport() {
        var state = DashboardState(projectIDs: ["a", "b", "c"])
        state.handleInput(.scrollDown)
        #expect(state.scrollOffset == 3)
        #expect(state.selectedIndex == 0)
    }

    @Test("Mouse scroll up in portfolio scrolls viewport")
    func scrollUpMovesViewport() {
        var state = DashboardState(projectIDs: ["a", "b", "c"])
        state.handleInput(.scrollDown)
        state.handleInput(.scrollUp)
        #expect(state.scrollOffset == 0)
        #expect(state.selectedIndex == 0)
    }

    @Test("Page down in portfolio scrolls viewport by half screen")
    func pageDownScrollsViewport() {
        var state = DashboardState(projectIDs: (0..<50).map { "p\($0)" })
        state.terminalHeight = 24
        state.handleInput(.pageDown)
        #expect(state.scrollOffset == 12)
        #expect(state.selectedIndex == 0)
    }

    @Test("Detail arrow down scrolls content by 1")
    func detailArrowDownScrolls() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter)
        state.handleInput(.arrowDown)
        #expect(state.scrollOffset == 1)
    }

    @Test("Detail mouse scroll moves by 3 lines")
    func detailMouseScroll() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter)
        state.handleInput(.scrollDown)
        #expect(state.scrollOffset == 3)
        state.handleInput(.scrollUp)
        #expect(state.scrollOffset == 0)
    }

    @Test("Detail PageDown scrolls by half screen")
    func detailPageDown() {
        var state = DashboardState(projectIDs: ["a"])
        state.terminalHeight = 20
        state.handleInput(.enter)
        state.handleInput(.pageDown)
        #expect(state.scrollOffset == 10)
    }

    @Test("Tab switch resets scroll offset")
    func tabSwitchResetsScroll() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter)
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown)
        #expect(state.scrollOffset == 2)
        state.handleInput(.tab)
        #expect(state.scrollOffset == 0)
    }

    @Test("Returning to portfolio resets scroll offset")
    func escapeResetsScroll() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter)
        state.handleInput(.arrowDown)
        state.handleInput(.escape)
        #expect(state.scrollOffset == 0)
    }

    // MARK: - Click

    @Test("Click on project row selects and drills in")
    func clickSelectsProject() {
        var state = DashboardState(projectIDs: ["alpha", "beta", "gamma"])
        state.handleInput(.click(row: 8, column: 10))
        #expect(state.selectedIndex == 1)
        #expect(state.currentView == .projectDetail)
    }

    @Test("Click outside project rows does nothing")
    func clickOutsideRows() {
        var state = DashboardState(projectIDs: ["alpha", "beta"])
        state.handleInput(.click(row: 2, column: 10))
        #expect(state.currentView == .portfolio)
        #expect(state.selectedIndex == 0)
    }

    // MARK: - Quit Signal

    @Test("Q key in portfolio signals quit")
    func quitFromPortfolio() {
        var state = DashboardState(projectIDs: ["alpha"])
        state.handleInput(.quit)
        #expect(state.shouldQuit)
    }

    // MARK: - Project ID Updates

    @Test("updateProjectIDs preserves selection by ID")
    func updatePreservesSelection() {
        var state = DashboardState(projectIDs: ["alpha", "beta", "gamma"])
        state.handleInput(.arrowDown) // select beta
        state.updateProjectIDs(["alpha", "beta", "delta", "gamma"])
        #expect(state.selectedProjectID == "beta")
        #expect(state.selectedIndex == 1)
    }

    @Test("updateProjectIDs clamps index when selected project removed")
    func updateClampsOnRemoval() {
        var state = DashboardState(projectIDs: ["alpha", "beta", "gamma"])
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown) // select gamma (index 2)
        state.updateProjectIDs(["alpha", "beta"])
        #expect(state.selectedIndex == 1)
    }

    // MARK: - Sort

    @Test("cycleSort advances through all sort keys and wraps back to name")
    func cycleSortAdvancesKeys() {
        var state = DashboardState(projectIDs: ["a", "b"])
        #expect(state.sortKey == .name)
        state.handleInput(.cycleSort)
        #expect(state.sortKey == .status)
        state.handleInput(.cycleSort)
        #expect(state.sortKey == .passRate)
        state.handleInput(.cycleSort)
        #expect(state.sortKey == .runs)
        state.handleInput(.cycleSort)
        #expect(state.sortKey == .name)
    }

    @Test("cycleSort resets scroll offset")
    func cycleSortResetsScroll() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.handleInput(.scrollDown)
        #expect(state.scrollOffset > 0)
        state.handleInput(.cycleSort)
        #expect(state.scrollOffset == 0)
    }

    @Test("cycleSort starts each new key ascending")
    func cycleSortNewKeyIsAscending() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.cycleSort) // → .status
        #expect(state.sortAscending)
        state.handleInput(.cycleSort) // → .passRate
        #expect(state.sortAscending)
        state.handleInput(.cycleSort) // → .runs
        #expect(state.sortAscending)
    }

    // MARK: - Label Navigation

    @Test("Arrow left in portfolio decrements label index")
    func arrowLeftPreviousLabel() {
        var state = DashboardState(projectIDs: ["a"])
        state.setAvailableLabels(["2026-W18", "2026-W19", "2026-W20"])
        #expect(state.selectedLabelIndex == 2)
        state.handleInput(.arrowLeft)
        #expect(state.selectedLabelIndex == 1)
        #expect(state.selectedLabel == "2026-W19")
    }

    @Test("Arrow right in portfolio increments label index")
    func arrowRightNextLabel() {
        var state = DashboardState(projectIDs: ["a"])
        state.setAvailableLabels(["2026-W18", "2026-W19", "2026-W20"])
        state.handleInput(.arrowLeft)
        state.handleInput(.arrowRight)
        #expect(state.selectedLabelIndex == 2)
        #expect(state.selectedLabel == "2026-W20")
    }

    @Test("Arrow left clamps at first label")
    func arrowLeftClampsAtFirst() {
        var state = DashboardState(projectIDs: ["a"])
        state.setAvailableLabels(["2026-W18", "2026-W19"])
        state.handleInput(.arrowLeft)
        state.handleInput(.arrowLeft)
        state.handleInput(.arrowLeft)
        #expect(state.selectedLabelIndex == 0)
        #expect(state.selectedLabel == "2026-W18")
    }

    @Test("Arrow right clamps at latest label")
    func arrowRightClampsAtLatest() {
        var state = DashboardState(projectIDs: ["a"])
        state.setAvailableLabels(["2026-W18", "2026-W19"])
        state.handleInput(.arrowRight)
        state.handleInput(.arrowRight)
        #expect(state.selectedLabelIndex == 1)
        #expect(state.selectedLabel == "2026-W19")
    }

    @Test("Arrow left/right no-ops when no labels available")
    func arrowLeftRightNoLabels() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.arrowLeft)
        state.handleInput(.arrowRight)
        #expect(state.selectedLabelIndex == nil)
        #expect(state.selectedLabel == nil)
    }

    @Test("setAvailableLabels selects specific label")
    func setAvailableLabelsWithInitialLabel() {
        var state = DashboardState(projectIDs: ["a"])
        state.setAvailableLabels(["2026-W18", "2026-W19", "2026-W20"], selecting: "2026-W19")
        #expect(state.selectedLabelIndex == 1)
        #expect(state.selectedLabel == "2026-W19")
    }

    @Test("labelChanged flag set on navigation and cleared on read")
    func labelChangedFlag() {
        var state = DashboardState(projectIDs: ["a"])
        state.setAvailableLabels(["2026-W18", "2026-W19", "2026-W20"])
        #expect(!state.labelChanged)
        state.handleInput(.arrowLeft)
        #expect(state.labelChanged)
        state.clearLabelChanged()
        #expect(!state.labelChanged)
    }

    @Test("cycleSort on the same key already active toggles sortAscending")
    func cycleSortWrapsAndTogglesDirection() {
        var state = DashboardState(projectIDs: ["a"])
        // Cycle through all 4 keys back to .name (wrap toggles sortAscending)
        state.handleInput(.cycleSort) // → .status  asc
        state.handleInput(.cycleSort) // → .passRate asc
        state.handleInput(.cycleSort) // → .runs     asc
        state.handleInput(.cycleSort) // → .name     direction toggled → false
        #expect(state.sortKey == .name)
        #expect(state.sortAscending == false)
        // Second full cycle wraps again, toggling back to true
        state.handleInput(.cycleSort) // → .status  asc
        state.handleInput(.cycleSort) // → .passRate asc
        state.handleInput(.cycleSort) // → .runs     asc
        state.handleInput(.cycleSort) // → .name     direction toggled → true
        #expect(state.sortKey == .name)
        #expect(state.sortAscending == true)
    }
}
