import Foundation

/// The result of comparing a gate run against institutional Pulse history.
///
/// Contains all consistency findings and an overall score. The score
/// populates `CheckResultMetadata.consistencyScore` — the field that
/// has been nil since Phase 1, now finally computed.
public struct ConsistencyReport: Sendable, Codable, Equatable {
    /// The project ID that was audited.
    public let projectID: String
    /// When the audit was performed.
    public let timestamp: Date
    /// The Pulse used as the institutional baseline.
    public let pulseWeekLabel: String
    /// All consistency findings detected.
    public let findings: [ConsistencyFinding]
    /// Overall consistency score (0.0 = fully inconsistent, 1.0 = fully consistent).
    public let consistencyScore: Double
    /// The Pulse's statistical validity for this project's trends.
    public let baselineValidity: StatisticalValidity

    /// Number of findings detected.
    public var findingsCount: Int { findings.count }

    /// Findings that match recurring Pulse clusters.
    public var recurringFindings: [ConsistencyFinding] {
        findings.filter(\.isRecurringInPulse)
    }

    /// Finding counts by match type (for scorer calibration telemetry).
    public var findingCountsByType: [ConsistencyMatchType: Int] {
        Dictionary(grouping: findings, by: \.matchType)
            .mapValues(\.count)
    }

    /// Fraction of findings that are recurring (for scorer calibration).
    public var recurringFraction: Double {
        guard !findings.isEmpty else { return 0.0 }
        return Double(recurringFindings.count) / Double(findings.count) // fp-safety:disable guarded by isEmpty
    }

    /// Creates a new consistency report.
    /// - Parameters:
    ///   - projectID: The project ID that was audited.
    ///   - timestamp: When the audit was performed.
    ///   - pulseWeekLabel: The Pulse week label used as baseline.
    ///   - findings: All consistency findings detected.
    ///   - consistencyScore: Overall consistency score (0.0-1.0).
    ///   - baselineValidity: Statistical validity of the Pulse baseline.
    public init(
        projectID: String,
        timestamp: Date,
        pulseWeekLabel: String,
        findings: [ConsistencyFinding],
        consistencyScore: Double,
        baselineValidity: StatisticalValidity
    ) {
        self.projectID = projectID
        self.timestamp = timestamp
        self.pulseWeekLabel = pulseWeekLabel
        self.findings = findings
        self.consistencyScore = consistencyScore
        self.baselineValidity = baselineValidity
    }
}
