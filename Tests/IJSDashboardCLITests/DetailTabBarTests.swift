import Testing
@testable import IJSDashboardCLI

/// Verifies the tab-bar geometry that keeps the rendered tab bar and the mouse
/// hit-tester in sync.
@Suite("DetailTabBar")
struct DetailTabBarTests {

    @Test("Regions cover every tab in order")
    func regionsCoverAllTabs() {
        let regions = DetailTabBar.regions()
        #expect(regions.map(\.tab) == DetailTab.allCases)
    }

    @Test("Regions start after the indent and are gap-separated, non-overlapping")
    func regionsLayout() {
        let regions = DetailTabBar.regions()
        // First label starts one column past the indent (1-based columns).
        #expect(regions.first?.columns.lowerBound == DetailTabBar.indent + 1)

        // Each label is exactly its visible length wide.
        for region in regions {
            let width = region.columns.upperBound - region.columns.lowerBound + 1
            #expect(width == region.tab.label.count)
        }

        // Consecutive labels are separated by exactly `gap` columns and never overlap.
        for pair in zip(regions, regions.dropFirst()) {
            let gap = pair.1.columns.lowerBound - pair.0.columns.upperBound - 1
            #expect(gap == DetailTabBar.gap)
        }
    }

    @Test("Click on a label column maps to that tab")
    func tabAtColumnMapsToLabel() {
        for region in DetailTabBar.regions() {
            let mid = (region.columns.lowerBound + region.columns.upperBound) / 2
            let hit = DetailTabBar.tab(
                atRow: DetailTabBar.barLineIndex + 1,
                column: mid,
                scrollOffset: 0
            )
            #expect(hit == region.tab)
        }
    }

    @Test("Click in the indent gutter maps to no tab")
    func tabInIndentIsNil() {
        let hit = DetailTabBar.tab(
            atRow: DetailTabBar.barLineIndex + 1,
            column: 1,
            scrollOffset: 0
        )
        #expect(hit == nil)
    }

    @Test("Click off the tab-bar line maps to no tab")
    func tabOffBarLineIsNil() {
        let checkers = DetailTabBar.regions().first { $0.tab == .checkers }
        let col = checkers?.columns.lowerBound ?? 12
        let hit = DetailTabBar.tab(
            atRow: DetailTabBar.barLineIndex + 3,
            column: col,
            scrollOffset: 0
        )
        #expect(hit == nil)
    }

    @Test("Scroll offset shifts the hit-tested bar line")
    func scrollOffsetShiftsBarLine() {
        let checkers = DetailTabBar.regions().first { $0.tab == .checkers }
        let col = checkers?.columns.lowerBound ?? 12
        // At scrollOffset 2, render-line `barLineIndex` shows on screen row
        // `barLineIndex - 2 + 1`.
        let hit = DetailTabBar.tab(
            atRow: DetailTabBar.barLineIndex - 1,
            column: col,
            scrollOffset: 2
        )
        #expect(hit == .checkers)
    }
}
