import Foundation

/// A named group of related projects for aggregated analysis.
public struct ProjectGroup: Sendable, Codable, Equatable {
    /// Unique identifier for this group.
    public let groupID: String
    /// Project IDs belonging to this group.
    public let memberProjectIDs: [String]

    /// Creates a project group with the given ID and member projects.
    public init(groupID: String, memberProjectIDs: [String]) {
        self.groupID = groupID
        self.memberProjectIDs = memberProjectIDs
    }

    /// Returns true if the given project ID is a member of this group.
    public func contains(projectID: String) -> Bool {
        memberProjectIDs.contains(projectID)
    }
}
