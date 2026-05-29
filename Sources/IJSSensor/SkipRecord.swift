import Foundation

/// Records a quality-gate skip event with an issue reference for accountability.
public struct SkipRecord: Sendable, Codable, Equatable {
    /// Project identifier.
    public let projectID: String
    /// When the skip occurred.
    public let timestamp: Date
    /// Issue URL or reference justifying the skip.
    public let issueReference: String
    /// Who triggered the skip.
    public let author: String
    /// Execution environment (local or CI).
    public let environment: Environment

    /// Creates a new skip record.
    public init(
        projectID: String,
        timestamp: Date,
        issueReference: String,
        author: String,
        environment: Environment
    ) {
        self.projectID = projectID
        self.timestamp = timestamp
        self.issueReference = issueReference
        self.author = author
        self.environment = environment
    }
}
