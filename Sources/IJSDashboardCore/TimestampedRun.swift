import Foundation
import IJSSensor

/// A quality gate run anchored to its execution timestamp.
public struct TimestampedRun: Sendable {
    /// The full metadata captured during this gate execution.
    public let metadata: CheckResultMetadata

    /// Creates a timestamped run from gate metadata.
    public init(metadata: CheckResultMetadata) {
        self.metadata = metadata
    }
}
