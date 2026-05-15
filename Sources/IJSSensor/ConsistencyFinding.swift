import Foundation

/// A single instance where a current gate result matches a known institutional pattern.
///
/// Produced by PolicyDiscoveryAuditor when a failure in the current gate run
/// matches a ViolationCluster or anomaly pattern from the most recent Pulse.
public struct ConsistencyFinding: Sendable, Codable, Equatable {
    /// The rule ID that triggered the finding.
    public let ruleId: String
    /// The checker that reported the violation.
    public let checkerId: String
    /// How this finding relates to institutional history.
    public let matchType: ConsistencyMatchType
    /// The risk tier of the original violation cluster, if matched.
    public let clusterRiskWeight: Double
    /// The number of times this pattern has appeared in Pulse history.
    public let historicalOccurrences: Int
    /// Whether this pattern was marked as recurring in the most recent Pulse.
    public let isRecurringInPulse: Bool
    /// Human-readable explanation of why this is an institutional concern.
    public let explanation: String

    /// Creates a new consistency finding.
    /// - Parameters:
    ///   - ruleId: The rule ID that triggered the finding.
    ///   - checkerId: The checker that reported the violation.
    ///   - matchType: How this finding relates to institutional history.
    ///   - clusterRiskWeight: The risk weight of the original cluster.
    ///   - historicalOccurrences: How many times this pattern appeared historically.
    ///   - isRecurringInPulse: Whether this pattern is recurring in the Pulse.
    ///   - explanation: Human-readable explanation of the institutional concern.
    public init(
        ruleId: String,
        checkerId: String,
        matchType: ConsistencyMatchType,
        clusterRiskWeight: Double,
        historicalOccurrences: Int,
        isRecurringInPulse: Bool,
        explanation: String
    ) {
        self.ruleId = ruleId
        self.checkerId = checkerId
        self.matchType = matchType
        self.clusterRiskWeight = clusterRiskWeight
        self.historicalOccurrences = historicalOccurrences
        self.isRecurringInPulse = isRecurringInPulse
        self.explanation = explanation
    }
}
