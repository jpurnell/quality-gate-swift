import Foundation

/// A periodic summary of institutional learning derived from quality gate telemetry.
///
/// Each Pulse covers a fixed time window (typically one week) and contains
/// computed statistics with full trend analysis and anomaly detection,
/// violation clusters, and optional narrative.
public struct InstitutionalPulse: Sendable, Codable, Equatable {
    /// The time window this Pulse covers.
    public let windowStart: Date
    /// End of the time window (exclusive).
    public let windowEnd: Date
    /// ISO week label (e.g., "2026-W18").
    public let weekLabel: String
    /// Projects included in this Pulse.
    public let projects: [String]
    /// Aggregated statistics with trends and anomalies.
    public let statistics: PulseStatistics
    /// Detected violation clusters (recurring patterns).
    public let violationClusters: [ViolationCluster]
    /// Policy updates proposed by calibrations in this window.
    public let proposedPolicyUpdates: [String]
    /// Pulse contributions from calibrations (2-3 sentence summaries).
    public let calibrationSummaries: [String]
    /// LLM-generated or human-written narrative synthesis (nil until summarized).
    public let narrative: String?
    /// When this Pulse was generated.
    public let generatedAt: Date

    /// Creates a new institutional pulse.
    public init(
        windowStart: Date,
        windowEnd: Date,
        weekLabel: String,
        projects: [String],
        statistics: PulseStatistics,
        violationClusters: [ViolationCluster],
        proposedPolicyUpdates: [String],
        calibrationSummaries: [String],
        narrative: String?,
        generatedAt: Date
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.weekLabel = weekLabel
        self.projects = projects
        self.statistics = statistics
        self.violationClusters = violationClusters
        self.proposedPolicyUpdates = proposedPolicyUpdates
        self.calibrationSummaries = calibrationSummaries
        self.narrative = narrative
        self.generatedAt = generatedAt
    }
}
