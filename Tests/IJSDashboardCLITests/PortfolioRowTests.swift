import Testing
import Foundation
@testable import IJSDashboardCLI

@Suite("PortfolioRow + Visible Row Computation")
struct PortfolioRowTests {

    // MARK: - No Groups

    @Test("No groups returns all projects as standalone rows")
    func noGroupsAllStandalone() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: ["alpha", "beta", "gamma"],
            groups: [:],
            expandedGroups: []
        )
        #expect(rows == [
            .project(projectID: "alpha"),
            .project(projectID: "beta"),
            .project(projectID: "gamma"),
        ])
    }

    // MARK: - Collapsed Groups

    @Test("Collapsed group shows group header only")
    func collapsedGroupHeaderOnly() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: ["appA", "appB", "lib"],
            groups: ["MyGroup": ["appA", "appB"]],
            expandedGroups: []
        )
        #expect(rows == [
            .group(groupID: "MyGroup"),
            .project(projectID: "lib"),
        ])
    }

    @Test("Multiple collapsed groups show headers only")
    func multipleCollapsedGroups() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: ["a", "b", "c", "d"],
            groups: ["Alpha": ["a", "b"], "Beta": ["c"]],
            expandedGroups: []
        )
        #expect(rows == [
            .group(groupID: "Alpha"),
            .group(groupID: "Beta"),
            .project(projectID: "d"),
        ])
    }

    // MARK: - Expanded Groups

    @Test("Expanded group shows header then member rows")
    func expandedGroupShowsMembers() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: ["alpha", "zulu", "bravo"],
            groups: ["Team": ["alpha", "zulu"]],
            expandedGroups: ["Team"]
        )
        #expect(rows == [
            .group(groupID: "Team"),
            .project(projectID: "alpha"),
            .project(projectID: "zulu"),
            .project(projectID: "bravo"),
        ])
    }

    @Test("Expanded group members follow projectIDs sort order")
    func expandedGroupRespectsSort() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: ["c", "a", "b"],
            groups: ["G": ["a", "c"]],
            expandedGroups: ["G"]
        )
        #expect(rows == [
            .group(groupID: "G"),
            .project(projectID: "c"),
            .project(projectID: "a"),
            .project(projectID: "b"),
        ])
    }

    // MARK: - Ordering

    @Test("Groups sorted alphabetically before ungrouped projects")
    func groupsSortedAlphabetically() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: ["x", "a", "b", "c"],
            groups: ["Zebra": ["a"], "Alpha": ["b"]],
            expandedGroups: []
        )
        #expect(rows == [
            .group(groupID: "Alpha"),
            .group(groupID: "Zebra"),
            .project(projectID: "x"),
            .project(projectID: "c"),
        ])
    }

    @Test("Ungrouped projects preserve projectIDs order")
    func ungroupedPreserveOrder() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: ["z", "m", "a", "g"],
            groups: ["G": ["a"]],
            expandedGroups: []
        )
        #expect(rows == [
            .group(groupID: "G"),
            .project(projectID: "z"),
            .project(projectID: "m"),
            .project(projectID: "g"),
        ])
    }

    // MARK: - Edge Cases

    @Test("Group with no active members is hidden")
    func groupWithNoActiveMembersHidden() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: ["x"],
            groups: ["Empty": ["notInList"]],
            expandedGroups: []
        )
        #expect(rows == [
            .project(projectID: "x"),
        ])
    }

    @Test("Empty projectIDs with groups returns nothing")
    func emptyProjectIDs() {
        let rows = DashboardState.buildVisibleRows(
            projectIDs: [],
            groups: ["G": ["a"]],
            expandedGroups: []
        )
        #expect(rows.isEmpty)
    }
}
