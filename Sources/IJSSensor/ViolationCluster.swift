import Foundation

/// A recurring pattern of violations detected across telemetry within a time window.
///
/// Clusters are identified by matching `ruleId` values across multiple gate runs.
/// A cluster signals an institutional gap — the same mistake keeps happening,
/// suggesting missing guidance rather than individual error.
public struct ViolationCluster: Sendable, Codable, Equatable {
    /// The rule ID that recurs (e.g., "concurrency.unchecked-sendable").
    public let ruleId: String
    /// How many times this rule was violated in the time window.
    public let occurrenceCount: Int
    /// How many distinct projects triggered this rule.
    public let affectedProjectCount: Int
    /// The most common root cause adjective from calibrations referencing this rule.
    public let dominantRootCause: String?
    /// The most common failed 5-Step stage from calibrations referencing this rule.
    public let dominantFailedStep: FiveStepStage?
    /// Whether this cluster appeared in the previous Pulse (recurring vs. new).
    public let isRecurring: Bool

    /// Creates a new violation cluster.
    public init(
        ruleId: String,
        occurrenceCount: Int,
        affectedProjectCount: Int,
        dominantRootCause: String?,
        dominantFailedStep: FiveStepStage?,
        isRecurring: Bool
    ) {
        self.ruleId = ruleId
        self.occurrenceCount = occurrenceCount
        self.affectedProjectCount = affectedProjectCount
        self.dominantRootCause = dominantRootCause
        self.dominantFailedStep = dominantFailedStep
        self.isRecurring = isRecurring
    }
}
