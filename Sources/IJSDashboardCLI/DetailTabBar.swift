import Foundation

/// Geometry for the project detail-view tab bar.
///
/// The rendered tab bar (``ProjectDetailTUIView/renderTabBar(into:selectedTab:width:)``)
/// and the mouse hit-tester (``DashboardState``) both derive their column layout
/// from this one place, so a click always lands on the tab the user sees. The
/// tab labels themselves come from ``DetailTab/label``.
enum DetailTabBar {
    /// Render-line index (0-based) of the tab bar within the detail frame.
    ///
    /// The detail frame opens with the title rule (line 0), a blank line
    /// (line 1), then the tab bar (line 2). If that preamble changes, update this
    /// constant — `tabBarOnExpectedLine` guards the alignment.
    static let barLineIndex = 2

    /// Leading indent (columns) before the first tab label.
    static let indent = 2

    /// Blank columns between adjacent tab labels.
    static let gap = 2

    /// The 1-based inclusive column range each tab label occupies on the bar line.
    ///
    /// Labels are ASCII, so `label.count` equals the visible column width and the
    /// ANSI styling applied when drawing adds no width.
    static func regions() -> [(tab: DetailTab, columns: ClosedRange<Int>)] {
        var result: [(tab: DetailTab, columns: ClosedRange<Int>)] = []
        var col = indent + 1
        for tab in DetailTab.allCases {
            let width = tab.label.count
            result.append((tab: tab, columns: col...(col + width - 1)))
            col += width + gap
        }
        return result
    }

    /// The tab under a 1-based `(row, column)` click for the given scroll offset,
    /// or `nil` when the click is not on a tab label.
    ///
    /// The whole detail frame scrolls uniformly, so a screen row maps back to a
    /// render line by adding the scroll offset.
    static func tab(atRow row: Int, column: Int, scrollOffset: Int) -> DetailTab? {
        let renderLine = row - 1 + scrollOffset
        guard renderLine == barLineIndex else { return nil }
        for region in regions() where region.columns.contains(column) {
            return region.tab
        }
        return nil
    }
}
