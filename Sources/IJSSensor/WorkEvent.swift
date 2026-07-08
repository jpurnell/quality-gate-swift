import Foundation

/// A compact, per-project record of the causal work behind a gate run.
///
/// The narrative generator can observe metrics move over time, but without a
/// causal record it cannot explain *why*. A ``WorkEvent`` captures the git
/// provenance (commit SHA and new commit subjects), plus optional
/// `CHANGELOG` and session-summary context, so downstream tooling can join a
/// metric snapshot (via ``CheckResultMetadata/commitSHA``) to the human work
/// that produced it.
///
/// Work-events form an idempotent, append-mostly stream keyed on the
/// calendar-day of ``date`` and ``commitSHA``: writing the same day+SHA twice
/// replaces the earlier entry rather than duplicating it.
public struct WorkEvent: Sendable, Codable, Equatable {
    /// The run day this work-event was captured on.
    public let date: Date
    /// Git commit SHA the gate ran against; the join key to the metric snapshot. Nil if not a git repo.
    public let commitSHA: String?
    /// Subjects of commits new since the last recorded work-log entry.
    public let commitSubjects: [String]
    /// The top unreleased `CHANGELOG` section text at run time, if available.
    public let changelogDelta: String?
    /// The newest session-summary text at run time, if available.
    public let sessionSummary: String?

    /// Creates a new work-event.
    /// - Parameters:
    ///   - date: The run day this work-event was captured on.
    ///   - commitSHA: Git commit SHA the gate ran against. Nil if not a git repo.
    ///   - commitSubjects: Subjects of commits new since the last recorded entry.
    ///   - changelogDelta: Top unreleased `CHANGELOG` section text, if available.
    ///   - sessionSummary: Newest session-summary text, if available.
    public init(
        date: Date,
        commitSHA: String?,
        commitSubjects: [String],
        changelogDelta: String?,
        sessionSummary: String?
    ) {
        self.date = date
        self.commitSHA = commitSHA
        self.commitSubjects = commitSubjects
        self.changelogDelta = changelogDelta
        self.sessionSummary = sessionSummary
    }

    /// Decodes a ``WorkEvent``, defaulting `commitSubjects` to `[]` and the optional text fields to `nil` when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
        commitSubjects = try container.decodeIfPresent([String].self, forKey: .commitSubjects) ?? []
        changelogDelta = try container.decodeIfPresent(String.self, forKey: .changelogDelta)
        sessionSummary = try container.decodeIfPresent(String.self, forKey: .sessionSummary)
    }
}
