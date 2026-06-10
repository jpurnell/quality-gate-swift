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
    /// Generic label (date or week) used for pulse directory naming.
    /// When present, takes priority over weekLabel for file I/O.
    public let label: String?
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
    /// Per-project tier classifications based on engagement level.
    public let projectTiers: [String: ProjectTier]?
    /// Per-project trajectory analyses for weighted quality scores.
    public let projectTrajectories: [ProjectTrajectory]?
    /// Group-level aggregated snapshots keyed by group ID.
    public let groupSnapshots: [String: [DailySnapshot]]?
    /// Point-in-time snapshot from the latest run per project.
    public let currentSnapshot: CurrentSnapshot?

    private enum CodingKeys: String, CodingKey {
        case windowStart, windowEnd, weekLabel, label, projects
        case statistics, violationClusters, proposedPolicyUpdates
        case calibrationSummaries, narrative, generatedAt
        case projectTiers, projectTrajectories, groupSnapshots
        case currentSnapshot
    }

    /// Creates a new institutional pulse.
    public init(
        windowStart: Date,
        windowEnd: Date,
        weekLabel: String,
        label: String? = nil,
        projects: [String],
        statistics: PulseStatistics,
        violationClusters: [ViolationCluster],
        proposedPolicyUpdates: [String],
        calibrationSummaries: [String],
        narrative: String?,
        generatedAt: Date,
        projectTiers: [String: ProjectTier]? = nil,
        projectTrajectories: [ProjectTrajectory]? = nil,
        groupSnapshots: [String: [DailySnapshot]]? = nil,
        currentSnapshot: CurrentSnapshot? = nil
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.weekLabel = weekLabel
        self.label = label
        self.projects = projects
        self.statistics = statistics
        self.violationClusters = violationClusters
        self.proposedPolicyUpdates = proposedPolicyUpdates
        self.calibrationSummaries = calibrationSummaries
        self.narrative = narrative
        self.generatedAt = generatedAt
        self.projectTiers = projectTiers
        self.projectTrajectories = projectTrajectories
        self.groupSnapshots = groupSnapshots
        self.currentSnapshot = currentSnapshot
    }

    /// Returns a copy of this pulse with the narrative field set.
    public func withNarrative(_ text: String) -> InstitutionalPulse {
        InstitutionalPulse(
            windowStart: windowStart,
            windowEnd: windowEnd,
            weekLabel: weekLabel,
            label: label,
            projects: projects,
            statistics: statistics,
            violationClusters: violationClusters,
            proposedPolicyUpdates: proposedPolicyUpdates,
            calibrationSummaries: calibrationSummaries,
            narrative: text,
            generatedAt: generatedAt,
            projectTiers: projectTiers,
            projectTrajectories: projectTrajectories,
            groupSnapshots: groupSnapshots,
            currentSnapshot: currentSnapshot
        )
    }

    /// Decodes an institutional pulse, tolerating missing optional fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowStart = try container.decode(Date.self, forKey: .windowStart)
        windowEnd = try container.decode(Date.self, forKey: .windowEnd)
        weekLabel = try container.decode(String.self, forKey: .weekLabel)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        projects = try container.decode([String].self, forKey: .projects)
        statistics = try container.decode(PulseStatistics.self, forKey: .statistics)
        violationClusters = try container.decode([ViolationCluster].self, forKey: .violationClusters)
        proposedPolicyUpdates = try container.decode([String].self, forKey: .proposedPolicyUpdates)
        calibrationSummaries = try container.decode([String].self, forKey: .calibrationSummaries)
        narrative = try container.decodeIfPresent(String.self, forKey: .narrative)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        projectTiers = try container.decodeIfPresent([String: ProjectTier].self, forKey: .projectTiers)
        projectTrajectories = try container.decodeIfPresent([ProjectTrajectory].self, forKey: .projectTrajectories)
        groupSnapshots = try container.decodeIfPresent([String: [DailySnapshot]].self, forKey: .groupSnapshots)
        currentSnapshot = try container.decodeIfPresent(CurrentSnapshot.self, forKey: .currentSnapshot)
    }

    /// Encodes all pulse fields, omitting nil optional properties.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowStart, forKey: .windowStart)
        try container.encode(windowEnd, forKey: .windowEnd)
        try container.encode(weekLabel, forKey: .weekLabel)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(projects, forKey: .projects)
        try container.encode(statistics, forKey: .statistics)
        try container.encode(violationClusters, forKey: .violationClusters)
        try container.encode(proposedPolicyUpdates, forKey: .proposedPolicyUpdates)
        try container.encode(calibrationSummaries, forKey: .calibrationSummaries)
        try container.encodeIfPresent(narrative, forKey: .narrative)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(projectTiers, forKey: .projectTiers)
        try container.encodeIfPresent(projectTrajectories, forKey: .projectTrajectories)
        try container.encodeIfPresent(groupSnapshots, forKey: .groupSnapshots)
        try container.encodeIfPresent(currentSnapshot, forKey: .currentSnapshot)
    }
}
