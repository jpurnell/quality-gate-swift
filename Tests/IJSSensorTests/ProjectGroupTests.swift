import Testing
import Foundation
@testable import IJSSensor

@Suite("ProjectGroup")
struct ProjectGroupTests {

    @Test("Init stores groupID and memberProjectIDs")
    func initProperties() {
        let group = ProjectGroup(groupID: "team-alpha", memberProjectIDs: ["proj-1", "proj-2"])
        #expect(group.groupID == "team-alpha")
        #expect(group.memberProjectIDs == ["proj-1", "proj-2"])
    }

    @Test("Contains returns true for member project")
    func containsMember() {
        let group = ProjectGroup(groupID: "g1", memberProjectIDs: ["a", "b", "c"])
        #expect(group.contains(projectID: "b"))
    }

    @Test("Contains returns false for non-member project")
    func doesNotContainNonMember() {
        let group = ProjectGroup(groupID: "g1", memberProjectIDs: ["a", "b", "c"])
        #expect(!group.contains(projectID: "z"))
    }

    @Test("Empty memberProjectIDs returns false for any projectID")
    func emptyMembers() {
        let group = ProjectGroup(groupID: "empty", memberProjectIDs: [])
        #expect(!group.contains(projectID: "anything"))
    }

    @Test("Codable round-trip preserves all properties")
    func codableRoundTrip() throws {
        let group = ProjectGroup(groupID: "team-beta", memberProjectIDs: ["x", "y"])
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(group)
        let decoded = try decoder.decode(ProjectGroup.self, from: data)
        #expect(decoded == group)
    }

    @Test("Equatable compares all fields")
    func equatable() {
        let group1 = ProjectGroup(groupID: "g1", memberProjectIDs: ["a", "b"])
        let group2 = ProjectGroup(groupID: "g1", memberProjectIDs: ["a", "b"])
        let group3 = ProjectGroup(groupID: "g1", memberProjectIDs: ["a", "c"])
        #expect(group1 == group2)
        #expect(group1 != group3)
    }

    @Test("Groups with different IDs are not equal")
    func differentGroupIDs() {
        let group1 = ProjectGroup(groupID: "g1", memberProjectIDs: ["a"])
        let group2 = ProjectGroup(groupID: "g2", memberProjectIDs: ["a"])
        #expect(group1 != group2)
    }
}
