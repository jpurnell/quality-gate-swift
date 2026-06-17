import Foundation
import QualityGateTypes

/// A point-in-time summary of the portfolio based on the latest run per project.
///
/// Unlike window-aggregate statistics (which span 30 days and include historical
/// failures), the snapshot reflects the current state: how each project's most
/// recent gate run performed.
public struct CurrentSnapshot: Sendable, Codable, Equatable {
    /// Per-project status from the latest run.
    public let projects: [ProjectStatus]
    /// Total projects in the snapshot.
    public var totalProjects: Int { projects.count }
    /// Projects whose latest run passed all checkers.
    public var passingProjects: Int { projects.filter(\.allPassed).count }
    /// Projects whose latest run had at least one failure.
    public var failingProjects: Int { projects.filter { !$0.allPassed }.count }
    /// Total unique overrides across latest runs.
    public let totalOverrides: Int
    /// Total compliance annotations across latest runs.
    public let totalComplianceCount: Int
    /// Checkers that failed in the latest run, aggregated across projects.
    public let failingCheckers: [String: Int]

    /// Creates a snapshot from aggregated project statuses.
    /// - Parameters:
    ///   - projects: Per-project status entries.
    ///   - totalOverrides: Sum of overrides across all projects.
    ///   - totalComplianceCount: Sum of compliance annotations across all projects.
    ///   - failingCheckers: Checker IDs mapped to the number of projects in which they failed.
    public init(
        projects: [ProjectStatus],
        totalOverrides: Int,
        totalComplianceCount: Int,
        failingCheckers: [String: Int]
    ) {
        self.projects = projects
        self.totalOverrides = totalOverrides
        self.totalComplianceCount = totalComplianceCount
        self.failingCheckers = failingCheckers
    }

    /// Latest-run status for a single project.
    public struct ProjectStatus: Sendable, Codable, Equatable {
        /// Project identifier.
        public let projectID: String
        /// Whether all checkers passed in the latest run.
        public let allPassed: Bool
        /// Checkers that failed in the latest run.
        public let failedCheckers: [String]
        /// When the latest run occurred.
        public let lastRunDate: Date
        /// Number of overrides in the latest run.
        public let overrideCount: Int

        /// Creates a project status entry.
        /// - Parameters:
        ///   - projectID: Unique identifier for the project.
        ///   - allPassed: Whether every checker passed.
        ///   - failedCheckers: IDs of checkers that failed.
        ///   - lastRunDate: Timestamp of the most recent run.
        ///   - overrideCount: Number of active overrides.
        public init(
            projectID: String,
            allPassed: Bool,
            failedCheckers: [String],
            lastRunDate: Date,
            overrideCount: Int
        ) {
            self.projectID = projectID
            self.allPassed = allPassed
            self.failedCheckers = failedCheckers
            self.lastRunDate = lastRunDate
            self.overrideCount = overrideCount
        }
    }
}
