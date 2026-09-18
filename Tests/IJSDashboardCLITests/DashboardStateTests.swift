import Testing
import Foundation
@testable import IJSDashboardCLI
@testable import IJSDashboardCore
import CorpusKit
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

    @Test("Detail view has exactly three tabs: summary, checkers, inbox")
    func detailTabCases() {
        #expect(DetailTab.allCases == [.summary, .checkers, .inbox])
    }

    @Test("Right arrow moves to the next tab and clamps at the last")
    func arrowRightSwitchesTabClamped() {
        var state = DashboardState(projectIDs: ["alpha"])
        state.handleInput(.enter)
        #expect(state.selectedTab == .summary)
        state.handleInput(.arrowRight)
        #expect(state.selectedTab == .checkers)
        state.handleInput(.arrowRight)
        #expect(state.selectedTab == .inbox)
        state.handleInput(.arrowRight) // clamps — no wrap
        #expect(state.selectedTab == .inbox)
    }

    @Test("Left arrow moves to the previous tab and clamps at the first")
    func arrowLeftSwitchesTabClamped() {
        var state = DashboardState(projectIDs: ["alpha"])
        state.handleInput(.enter)
        state.handleInput(.arrowRight)
        #expect(state.selectedTab == .checkers)
        state.handleInput(.arrowLeft)
        #expect(state.selectedTab == .summary)
        state.handleInput(.arrowLeft) // clamps — no wrap
        #expect(state.selectedTab == .summary)
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
        state.handleInput(.arrowRight)
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

    @Test("Click aligns to rows when the compact pulse header is present")
    func clickWithPulseHeader() {
        var state = DashboardState(projectIDs: ["alpha", "beta", "gamma"])
        // The live dashboard renders a compact pulse line, so the preamble is
        // one row taller (7, not 6) and the first data row is terminal row 8.
        state.hasPulseHeader = true
        state.handleInput(.click(row: 8, column: 10))
        #expect(state.selectedIndex == 0)
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

    // MARK: - Group Navigation

    @Test("Right arrow on group row expands it")
    func rightArrowExpandsGroup() {
        var state = DashboardState(projectIDs: ["a", "b", "c"])
        state.updateGroups(["G": ["a", "b"]])
        // Row 0 is group "G", row 1 is ungrouped "c"
        #expect(state.visibleRows.count == 2)
        state.handleInput(.arrowRight)
        #expect(state.expandedGroups.contains("G"))
        // Now visible: group header + a + b + c
        #expect(state.visibleRows.count == 4)
    }

    @Test("Left arrow on expanded group row collapses it")
    func leftArrowCollapsesGroup() {
        var state = DashboardState(projectIDs: ["a", "b", "c"])
        state.updateGroups(["G": ["a", "b"]])
        state.handleInput(.arrowRight) // expand
        #expect(state.expandedGroups.contains("G"))
        state.handleInput(.arrowLeft) // collapse
        #expect(!state.expandedGroups.contains("G"))
        #expect(state.visibleRows.count == 2)
    }

    @Test("Left/right on project row navigates labels, not groups")
    func leftRightOnProjectNavigatesLabels() {
        var state = DashboardState(projectIDs: ["a", "b", "c"])
        state.updateGroups(["G": ["a"]])
        state.setAvailableLabels(["2026-W18", "2026-W19", "2026-W20"])
        // Move to ungrouped project row (index 1 = "b")
        state.handleInput(.arrowDown)
        #expect(state.selectedGroupID == nil)
        let labelBefore = state.selectedLabelIndex
        state.handleInput(.arrowLeft)
        #expect(state.selectedLabelIndex != labelBefore)
    }

    @Test("Enter on group row switches to groupDetail view")
    func enterOnGroupGoesToGroupDetail() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a"]])
        // Row 0 is group "G"
        state.handleInput(.enter)
        #expect(state.currentView == .groupDetail)
        #expect(state.selectedGroupID == "G")
    }

    @Test("Enter on project row switches to projectDetail")
    func enterOnProjectGoesToProjectDetail() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a"]])
        state.handleInput(.arrowDown) // move to ungrouped "b"
        state.handleInput(.enter)
        #expect(state.currentView == .projectDetail)
    }

    @Test("Escape from groupDetail returns to portfolio")
    func escapeFromGroupDetailReturnsToPortfolio() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a"]])
        state.handleInput(.enter) // go to groupDetail
        #expect(state.currentView == .groupDetail)
        state.handleInput(.escape)
        #expect(state.currentView == .portfolio)
    }

    @Test("selectedGroupID is nil when selection is on a project row")
    func selectedGroupIDNilOnProjectRow() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a"]])
        state.handleInput(.arrowDown) // move to project row
        #expect(state.selectedGroupID == nil)
    }

    @Test("Arrow down navigates through visible rows including groups")
    func arrowDownNavigatesVisibleRows() {
        var state = DashboardState(projectIDs: ["a", "b", "c"])
        state.updateGroups(["G": ["a", "b"]])
        // Collapsed: row 0 = group "G", row 1 = project "c"
        #expect(state.selectedIndex == 0)
        #expect(state.selectedGroupID == "G")
        state.handleInput(.arrowDown)
        #expect(state.selectedIndex == 1)
        #expect(state.selectedGroupID == nil)
    }

    // MARK: - Group Detail drill-in (collapsed group; blank-window regression)

    @Test("Enter on a group member opens that project's detail (group stays collapsed)")
    func groupEnterDrillsIntoMember() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a", "b"]])
        state.handleInput(.enter) // group G → groupDetail, member index 0
        #expect(state.currentView == .groupDetail)
        #expect(!state.expandedGroups.contains("G")) // collapsed — reproduces the old blank bug
        state.handleInput(.enter) // drill into member "a"
        #expect(state.currentView == .projectDetail)
        #expect(state.detailProjectID == "a")
    }

    @Test("Right arrow in group detail opens the selected member's detail")
    func groupRightArrowDrillsIn() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a", "b"]])
        state.handleInput(.enter) // groupDetail
        state.handleInput(.arrowDown) // member index 1 → "b"
        state.handleInput(.arrowRight) // drill into "b"
        #expect(state.currentView == .projectDetail)
        #expect(state.detailProjectID == "b")
    }

    @Test("Left arrow in group detail backs out to the portfolio")
    func groupLeftArrowBacksOut() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a", "b"]])
        state.handleInput(.enter) // groupDetail
        state.handleInput(.arrowLeft)
        #expect(state.currentView == .portfolio)
    }

    @Test("Group member drill-in respects the view's projectID sort order")
    func groupDrillInMatchesViewOrder() {
        // Portfolio order is reversed vs. the alphabetical order the view shows.
        var state = DashboardState(projectIDs: ["b", "a"])
        state.updateGroups(["G": ["a", "b"]])
        state.handleInput(.enter) // groupDetail, member index 0
        state.handleInput(.enter) // should open the FIRST alphabetical member, "a"
        #expect(state.detailProjectID == "a")
    }

    @Test("Click on a group member row selects and drills in")
    func groupClickDrillsIn() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a", "b"]])
        state.handleInput(.enter) // groupDetail
        // First member row renders at groupDetailHeaderLines (0-based) → screen row +1.
        state.handleInput(.click(row: state.groupDetailHeaderLines + 2, column: 5))
        #expect(state.selectedGroupMemberIndex == 1) // second member row
        #expect(state.currentView == .projectDetail)
        #expect(state.detailProjectID == "b")
    }

    @Test("Tier override from a group-drilled project targets that project")
    func groupDrillInTierOverride() {
        var state = DashboardState(projectIDs: ["a", "b"])
        state.updateGroups(["G": ["a", "b"]])
        state.handleInput(.enter) // groupDetail
        state.handleInput(.enter) // drill into "a" (summary tab)
        state.handleInput(.enter) // activate tier picker
        state.handleInput(.enter) // confirm default tier (dormant, index 0)
        #expect(state.pendingTierOverride?.projectID == "a")
    }

    // MARK: - Tier Picker (Summary tab)

    @Test("Enter on the summary tab activates the tier picker")
    func enterActivatesTierPicker() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter) // go to projectDetail (summary tab)
        #expect(state.selectedTab == .summary)
        #expect(!state.tierPickerActive)
        state.handleInput(.enter)
        #expect(state.tierPickerActive)
    }

    @Test("Enter on the checkers tab does not activate the tier picker")
    func enterOnCheckersNoPicker() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter)
        state.handleInput(.arrowRight) // checkers
        #expect(state.selectedTab == .checkers)
        state.handleInput(.enter)
        #expect(!state.tierPickerActive)
    }

    @Test("Arrow keys do not switch tabs while the tier picker is active")
    func arrowsDoNotSwitchTabWhilePicking() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter) // summary
        state.handleInput(.enter) // activate picker
        #expect(state.tierPickerActive)
        state.handleInput(.arrowRight)
        #expect(state.selectedTab == .summary)
        state.handleInput(.arrowLeft)
        #expect(state.selectedTab == .summary)
    }

    @Test("Tier picker navigates with arrow keys")
    func tierPickerNavigation() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter) // summary
        state.handleInput(.enter) // activate picker
        #expect(state.tierPickerIndex == 0)
        state.handleInput(.arrowDown)
        #expect(state.tierPickerIndex == 1)
        state.handleInput(.arrowDown)
        #expect(state.tierPickerIndex == 2)
        state.handleInput(.arrowUp)
        #expect(state.tierPickerIndex == 1)
    }

    @Test("Tier picker confirm sets pendingTierOverride")
    func tierPickerConfirm() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter) // summary
        state.handleInput(.enter) // activate picker
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown)
        state.handleInput(.arrowDown) // index 3 = baseline
        state.handleInput(.enter) // confirm
        #expect(!state.tierPickerActive)
        #expect(state.pendingTierOverride?.projectID == "a")
        #expect(state.pendingTierOverride?.tier == .baseline)
    }

    @Test("Tier picker escape cancels without setting override")
    func tierPickerEscapeCancels() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter) // summary
        state.handleInput(.enter) // activate picker
        state.handleInput(.arrowDown)
        state.handleInput(.escape) // cancel
        #expect(!state.tierPickerActive)
        #expect(state.pendingTierOverride == nil)
    }

    @Test("clearPendingTierOverride resets to nil")
    func clearPendingTierOverride() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter) // summary
        state.handleInput(.enter) // activate picker
        state.handleInput(.enter) // confirm with default tier (dormant, index 0)
        #expect(state.pendingTierOverride?.tier == .dormant)
        state.clearPendingTierOverride()
        #expect(state.pendingTierOverride == nil)
    }

    // MARK: - Clickable Tabs

    @Test("Click on the Checkers tab label activates the checkers tab")
    func clickActivatesCheckersTab() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter) // summary
        // Tab bar renders on render-line index 2 → screen row 3 at scrollOffset 0.
        // "Summary" occupies cols 3–9; "Checkers" begins after a 2-col gap at col 12.
        let checkers = DetailTabBar.regions().first { $0.tab == .checkers }
        let col = checkers?.columns.lowerBound ?? 12
        state.handleInput(.click(row: DetailTabBar.barLineIndex + 1, column: col))
        #expect(state.selectedTab == .checkers)
    }

    @Test("Click on the Summary tab label returns to the summary tab")
    func clickActivatesSummaryTab() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter)
        state.handleInput(.arrowRight) // checkers
        #expect(state.selectedTab == .checkers)
        let summary = DetailTabBar.regions().first { $0.tab == .summary }
        let col = summary?.columns.lowerBound ?? 3
        state.handleInput(.click(row: DetailTabBar.barLineIndex + 1, column: col))
        #expect(state.selectedTab == .summary)
    }

    @Test("Click off the tab-bar line leaves the tab unchanged")
    func clickOffTabBarLine() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter)
        state.handleInput(.click(row: DetailTabBar.barLineIndex + 5, column: 5))
        #expect(state.selectedTab == .summary)
    }

    @Test("Tab click hit-testing accounts for scroll offset")
    func clickTabWithScrollOffset() {
        var state = DashboardState(projectIDs: ["a"])
        state.handleInput(.enter)
        state.handleInput(.arrowDown) // scrollOffset == 1
        #expect(state.scrollOffset == 1)
        // With the frame scrolled up by 1, the tab bar now sits one screen row higher.
        let checkers = DetailTabBar.regions().first { $0.tab == .checkers }
        let col = checkers?.columns.lowerBound ?? 12
        state.handleInput(.click(row: DetailTabBar.barLineIndex, column: col))
        #expect(state.selectedTab == .checkers)
    }
}
